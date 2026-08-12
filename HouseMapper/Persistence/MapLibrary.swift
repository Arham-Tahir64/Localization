import ARKit
import Foundation
import UIKit

@MainActor
final class MapLibrary: ObservableObject {
    @Published private(set) var maps: [MapPackage] = []
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let mapsDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var sizeLoadingTask: Task<Void, Never>?
    private var sizeLoadGeneration = UUID()

    init(
        fileManager: FileManager = .default,
        mapsDirectory customMapsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        if let customMapsDirectory {
            mapsDirectory = customMapsDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            mapsDirectory = applicationSupport
                .appendingPathComponent("HouseMapper", isDirectory: true)
                .appendingPathComponent("Maps", isDirectory: true)
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        refresh()
    }

    func refresh() {
        do {
            try fileManager.createDirectory(
                at: mapsDirectory,
                withIntermediateDirectories: true
            )
            let directories = try fileManager.contentsOfDirectory(
                at: mapsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            let discoveredMaps: [MapPackage] = directories.compactMap { directory -> MapPackage? in
                guard let resourceValues = try? directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ),
                resourceValues.isDirectory == true,
                resourceValues.isSymbolicLink != true else {
                    return nil
                }
                let metadataURL = directory.appendingPathComponent("metadata.json")
                let worldMapURL = directory.appendingPathComponent("worldmap.arexperience")
                guard fileManager.fileExists(atPath: metadataURL.path),
                      fileManager.fileExists(atPath: worldMapURL.path),
                      let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? decoder.decode(MapMetadata.self, from: data),
                      metadata.schemaVersion <= MapMetadata.currentSchemaVersion,
                      UUID(uuidString: directory.lastPathComponent) == metadata.id else {
                    return nil
                }
                return MapPackage(metadata: metadata, directoryURL: directory)
            }
            .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
            maps = discoveredMaps
            loadPackageSizes(for: discoveredMaps)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save(
        worldMap: ARWorldMap,
        spatialMap: SpatialMapSnapshot,
        metadata: MapMetadata,
        previewData: Data?
    ) async throws -> MapPackage {
        guard spatialMap.mapID == metadata.id else {
            throw SpatialMapSnapshotError.mapIdentifierMismatch
        }
        let mapsDirectory = mapsDirectory
        let encodedMetadata = try encoder.encode(metadata)

        let package = try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: mapsDirectory,
                withIntermediateDirectories: true
            )

            let finalDirectory = mapsDirectory.appendingPathComponent(
                metadata.id.uuidString,
                isDirectory: true
            )
            let stagingDirectory = mapsDirectory.appendingPathComponent(
                ".staging-\(metadata.id.uuidString)-\(UUID().uuidString)",
                isDirectory: true
            )

            guard !fileManager.fileExists(atPath: finalDirectory.path) else {
                throw MapLibraryError.packageAlreadyExists
            }
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            do {
                let archive = try NSKeyedArchiver.archivedData(
                    withRootObject: worldMap,
                    requiringSecureCoding: true
                )
                try archive.write(
                    to: stagingDirectory.appendingPathComponent("worldmap.arexperience"),
                    options: [.atomic]
                )
                try encodedMetadata.write(
                    to: stagingDirectory.appendingPathComponent("metadata.json"),
                    options: [.atomic]
                )
                try SpatialMapSnapshotCodec.encode(spatialMap).write(
                    to: stagingDirectory.appendingPathComponent("spatial-map.plist"),
                    options: [.atomic]
                )
                if let previewData {
                    try previewData.write(
                        to: stagingDirectory.appendingPathComponent("preview.jpg"),
                        options: [.atomic]
                    )
                }

                try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
                return MapPackage(metadata: metadata, directoryURL: finalDirectory)
            } catch {
                try? fileManager.removeItem(at: stagingDirectory)
                throw error
            }
        }.value

        refresh()
        return package
    }

    @discardableResult
    func rename(_ package: MapPackage, to rawName: String) async throws -> MapPackage {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let error = MapLibraryError.emptyMapName
            lastError = error.localizedDescription
            throw error
        }

        let mapsDirectory = mapsDirectory
        do {
            let renamedPackage = try await Task.detached(priority: .userInitiated) {
                let directory = try Self.validatedDirectory(
                    for: package,
                    inside: mapsDirectory
                )
                let metadataURL = directory.appendingPathComponent("metadata.json")
                guard FileManager.default.fileExists(atPath: metadataURL.path) else {
                    throw MapLibraryError.packageNotFound
                }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let storedData = try Data(contentsOf: metadataURL)
                let storedMetadata = try decoder.decode(MapMetadata.self, from: storedData)
                guard storedMetadata.id == package.id else {
                    throw MapLibraryError.packageIdentifierMismatch
                }

                var metadata = storedMetadata
                metadata.name = name
                metadata.updatedAt = Date()

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let encodedMetadata = try encoder.encode(metadata)
                try encodedMetadata.write(to: metadataURL, options: [.atomic])

                return MapPackage(
                    metadata: metadata,
                    directoryURL: directory,
                    sizeInBytes: package.sizeInBytes
                )
            }.value

            refresh()
            return renamedPackage
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func delete(_ package: MapPackage) async throws {
        let mapsDirectory = mapsDirectory
        do {
            try await Task.detached(priority: .userInitiated) {
                let directory = try Self.validatedDirectory(
                    for: package,
                    inside: mapsDirectory
                )
                guard FileManager.default.fileExists(atPath: directory.path) else {
                    throw MapLibraryError.packageNotFound
                }
                try FileManager.default.removeItem(at: directory)
            }.value

            refresh()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func loadWorldMap(from package: MapPackage) async throws -> ARWorldMap {
        let mapsDirectory = mapsDirectory
        return try await Task.detached(priority: .userInitiated) {
            let directory = try Self.validatedDirectory(for: package, inside: mapsDirectory)
            let worldMapURL = directory.appendingPathComponent("worldmap.arexperience")
            let data = try Data(contentsOf: worldMapURL, options: [.mappedIfSafe])
            guard let map = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARWorldMap.self,
                from: data
            ) else {
                throw MapLibraryError.invalidWorldMap
            }
            return map
        }.value
    }

    func loadSpatialMap(from package: MapPackage) async throws -> SpatialMapSnapshot {
        let mapsDirectory = mapsDirectory
        return try await Task.detached(priority: .userInitiated) {
            let directory = try Self.validatedDirectory(for: package, inside: mapsDirectory)
            let spatialMapURL = directory.appendingPathComponent("spatial-map.plist")
            let snapshot: SpatialMapSnapshot
            if FileManager.default.fileExists(atPath: spatialMapURL.path) {
                let data = try Data(contentsOf: spatialMapURL, options: [.mappedIfSafe])
                snapshot = try SpatialMapSnapshotCodec.decode(data, expectedMapID: package.id)
            } else {
                // Schema-v1 compatibility: derive the app-owned snapshot from the same
                // ARWorldMap data that older packages already persisted losslessly.
                let worldMapURL = directory.appendingPathComponent("worldmap.arexperience")
                let data = try Data(contentsOf: worldMapURL, options: [.mappedIfSafe])
                guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: ARWorldMap.self,
                    from: data
                ) else {
                    throw MapLibraryError.invalidWorldMap
                }
                snapshot = try SpatialMapSnapshot(
                    mapID: package.id,
                    points: worldMap.rawFeaturePoints.points,
                    identifiers: worldMap.rawFeaturePoints.identifiers,
                    meshAnchors: try ARMeshSnapshotExtractor.records(from: worldMap.anchors)
                )
            }
            guard snapshot.landmarks.count == package.metadata.featurePointCount else {
                throw MapLibraryError.spatialMapFeatureCountMismatch(
                    expected: package.metadata.featurePointCount,
                    actual: snapshot.landmarks.count
                )
            }
            return snapshot
        }.value
    }

    func saveBenchmark(_ report: SessionBenchmarkReport, for package: MapPackage) async throws {
        guard report.map?.mapID == package.id else {
            throw MapLibraryError.invalidBenchmark
        }
        let mapsDirectory = mapsDirectory
        let data = try report.encodedJSON()
        try await Task.detached(priority: .utility) {
            let directory = try Self.validatedDirectory(for: package, inside: mapsDirectory)
            try data.write(
                to: directory.appendingPathComponent("benchmark.json"),
                options: .atomic
            )
        }.value
        refresh()
    }

    func loadBenchmark(for package: MapPackage) async throws -> SessionBenchmarkReport? {
        let mapsDirectory = mapsDirectory
        return try await Task.detached(priority: .utility) {
            let directory = try Self.validatedDirectory(for: package, inside: mapsDirectory)
            let url = directory.appendingPathComponent("benchmark.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(SessionBenchmarkReport.self, from: data)
            guard report.schemaVersion == SessionBenchmarkReport.currentSchemaVersion,
                  report.map?.mapID == package.id else {
                throw MapLibraryError.invalidBenchmark
            }
            return report
        }.value
    }

    func benchmarkStorageMetrics(for package: MapPackage) async throws -> (
        spatialMapByteCount: Int?,
        packageByteCount: Int64
    ) {
        let mapsDirectory = mapsDirectory
        return try await Task.detached(priority: .utility) {
            let directory = try Self.validatedDirectory(for: package, inside: mapsDirectory)
            let spatialMapURL = directory.appendingPathComponent("spatial-map.plist")
            let spatialBytes = try? spatialMapURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return (spatialBytes, Self.packageSize(at: directory))
        }.value
    }

    private func loadPackageSizes(for packages: [MapPackage]) {
        sizeLoadingTask?.cancel()
        let generation = UUID()
        sizeLoadGeneration = generation
        sizeLoadingTask = Task { [weak self] in
            let sizes = await Task.detached(priority: .utility) {
                packages.reduce(into: [UUID: Int64]()) { result, package in
                    guard !Task.isCancelled else { return }
                    result[package.id] = Self.packageSize(at: package.directoryURL)
                }
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.sizeLoadGeneration == generation else { return }
            maps = maps.map { package in
                MapPackage(
                    metadata: package.metadata,
                    directoryURL: package.directoryURL,
                    sizeInBytes: sizes[package.id]
                )
            }
        }
    }

    nonisolated private static func validatedDirectory(
        for package: MapPackage,
        inside mapsDirectory: URL
    ) throws -> URL {
        let resolvedMapsDirectory = mapsDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedPackageDirectory = package.directoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard resolvedPackageDirectory.deletingLastPathComponent() == resolvedMapsDirectory else {
            throw MapLibraryError.invalidPackageLocation
        }
        guard UUID(uuidString: resolvedPackageDirectory.lastPathComponent) == package.id else {
            throw MapLibraryError.packageIdentifierMismatch
        }
        return resolvedPackageDirectory
    }

    nonisolated private static func packageSize(at directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .totalFileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard !Task.isCancelled,
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

enum MapLibraryError: LocalizedError {
    case emptyMapName
    case invalidWorldMap
    case invalidPackageLocation
    case packageIdentifierMismatch
    case packageNotFound
    case packageAlreadyExists
    case invalidBenchmark
    case spatialMapFeatureCountMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .emptyMapName:
            return "Enter a name for the map."
        case .invalidWorldMap:
            return "The saved AR world map could not be decoded."
        case .invalidPackageLocation:
            return "The selected map is not stored directly in the map library."
        case .packageIdentifierMismatch:
            return "The selected map does not match its package folder."
        case .packageNotFound:
            return "The selected map is no longer available."
        case .packageAlreadyExists:
            return "A map package with this identifier already exists."
        case .invalidBenchmark:
            return "The saved device benchmark does not match this map package."
        case .spatialMapFeatureCountMismatch(let expected, let actual):
            return "The saved map metadata reports \(expected) landmarks, but its spatial payload contains \(actual)."
        }
    }
}
