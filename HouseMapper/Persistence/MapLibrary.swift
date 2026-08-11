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
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            let discoveredMaps = directories.compactMap { directory in
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
        metadata: MapMetadata,
        previewData: Data?
    ) async throws -> MapPackage {
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
                ".staging-\(metadata.id.uuidString)",
                isDirectory: true
            )

            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
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
                if let previewData {
                    try previewData.write(
                        to: stagingDirectory.appendingPathComponent("preview.jpg"),
                        options: [.atomic]
                    )
                }

                if fileManager.fileExists(atPath: finalDirectory.path) {
                    try fileManager.removeItem(at: finalDirectory)
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
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: package.worldMapURL, options: [.mappedIfSafe])
            guard let map = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARWorldMap.self,
                from: data
            ) else {
                throw MapLibraryError.invalidWorldMap
            }
            return map
        }.value
    }

    private func loadPackageSizes(for packages: [MapPackage]) {
        sizeLoadingTask?.cancel()
        sizeLoadingTask = Task { [weak self] in
            let sizes = await Task.detached(priority: .utility) {
                packages.reduce(into: [UUID: Int64]()) { result, package in
                    guard !Task.isCancelled else { return }
                    result[package.id] = Self.packageSize(at: package.directoryURL)
                }
            }.value

            guard !Task.isCancelled, let self else { return }
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
        }
    }
}
