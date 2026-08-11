import Foundation

struct MapMetadata: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    let appVersion: String
    let systemVersion: String
    let deviceModel: String
    let backend: String
    let center: Vector3Record
    let extent: Vector3Record
    let featurePointCount: Int
    let hasSceneDepth: Bool
    let hasSceneReconstruction: Bool
}

struct Vector3Record: Codable, Hashable, Sendable {
    let x: Float
    let y: Float
    let z: Float
}

struct MapPackage: Identifiable, Hashable, Sendable {
    let metadata: MapMetadata
    let directoryURL: URL
    let sizeInBytes: Int64?

    init(
        metadata: MapMetadata,
        directoryURL: URL,
        sizeInBytes: Int64? = nil
    ) {
        self.metadata = metadata
        self.directoryURL = directoryURL
        self.sizeInBytes = sizeInBytes
    }

    var id: UUID { metadata.id }
    var worldMapURL: URL { directoryURL.appendingPathComponent("worldmap.arexperience") }
    var previewURL: URL { directoryURL.appendingPathComponent("preview.jpg") }
}
