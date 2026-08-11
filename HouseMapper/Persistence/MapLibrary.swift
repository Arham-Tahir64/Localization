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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        mapsDirectory = applicationSupport
            .appendingPathComponent("HouseMapper", isDirectory: true)
            .appendingPathComponent("Maps", isDirectory: true)

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

            maps = directories.compactMap { directory in
                let metadataURL = directory.appendingPathComponent("metadata.json")
                let worldMapURL = directory.appendingPathComponent("worldmap.arexperience")
                guard fileManager.fileExists(atPath: metadataURL.path),
                      fileManager.fileExists(atPath: worldMapURL.path),
                      let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? decoder.decode(MapMetadata.self, from: data),
                      metadata.schemaVersion <= MapMetadata.currentSchemaVersion else {
                    return nil
                }
                return MapPackage(metadata: metadata, directoryURL: directory)
            }
            .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
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
}

enum MapLibraryError: LocalizedError {
    case invalidWorldMap

    var errorDescription: String? {
        switch self {
        case .invalidWorldMap:
            return "The saved AR world map could not be decoded."
        }
    }
}
