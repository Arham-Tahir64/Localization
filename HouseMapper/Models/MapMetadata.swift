import Foundation
import simd

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

struct SpatialLandmarkRecord: Codable, Hashable, Sendable {
    let id: UInt64
    let position: Vector3Record
}

struct SpatialBoundsRecord: Codable, Hashable, Sendable {
    let minimum: Vector3Record
    let maximum: Vector3Record
}

struct SpatialMapSnapshot: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mapID: UUID
    let landmarks: [SpatialLandmarkRecord]
    let bounds: SpatialBoundsRecord

    init(mapID: UUID, landmarks: [SpatialLandmarkRecord]) throws {
        var identifiers: Set<UInt64> = []
        identifiers.reserveCapacity(landmarks.count)
        for landmark in landmarks {
            guard identifiers.insert(landmark.id).inserted else {
                throw SpatialMapSnapshotError.duplicateLandmarkIdentifier(landmark.id)
            }
            guard landmark.position.x.isFinite,
                  landmark.position.y.isFinite,
                  landmark.position.z.isFinite else {
                throw SpatialMapSnapshotError.nonfiniteLandmark(landmark.id)
            }
        }

        schemaVersion = Self.currentSchemaVersion
        self.mapID = mapID
        self.landmarks = landmarks
        bounds = Self.bounds(for: landmarks)
    }

    init(
        mapID: UUID,
        points: [SIMD3<Float>],
        identifiers: [UInt64]
    ) throws {
        guard points.count == identifiers.count else {
            throw SpatialMapSnapshotError.landmarkCountMismatch(
                points: points.count,
                identifiers: identifiers.count
            )
        }
        try self.init(
            mapID: mapID,
            landmarks: zip(identifiers, points).map { identifier, point in
                SpatialLandmarkRecord(
                    id: identifier,
                    position: Vector3Record(x: point.x, y: point.y, z: point.z)
                )
            }
        )
    }

    private static func bounds(for landmarks: [SpatialLandmarkRecord]) -> SpatialBoundsRecord {
        guard let first = landmarks.first else {
            let zero = Vector3Record(x: 0, y: 0, z: 0)
            return SpatialBoundsRecord(minimum: zero, maximum: zero)
        }

        var minimum = first.position
        var maximum = first.position
        for landmark in landmarks.dropFirst() {
            let point = landmark.position
            minimum = Vector3Record(
                x: min(minimum.x, point.x),
                y: min(minimum.y, point.y),
                z: min(minimum.z, point.z)
            )
            maximum = Vector3Record(
                x: max(maximum.x, point.x),
                y: max(maximum.y, point.y),
                z: max(maximum.z, point.z)
            )
        }
        return SpatialBoundsRecord(minimum: minimum, maximum: maximum)
    }
}

enum SpatialMapSnapshotCodec {
    static func encode(_ snapshot: SpatialMapSnapshot) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data, expectedMapID: UUID) throws -> SpatialMapSnapshot {
        let decoded = try PropertyListDecoder().decode(SpatialMapSnapshot.self, from: data)
        guard decoded.schemaVersion == SpatialMapSnapshot.currentSchemaVersion else {
            throw SpatialMapSnapshotError.unsupportedSchema(decoded.schemaVersion)
        }
        guard decoded.mapID == expectedMapID else {
            throw SpatialMapSnapshotError.mapIdentifierMismatch
        }

        let validated = try SpatialMapSnapshot(
            mapID: decoded.mapID,
            landmarks: decoded.landmarks
        )
        guard validated.bounds == decoded.bounds else {
            throw SpatialMapSnapshotError.invalidBounds
        }
        return decoded
    }
}

enum SpatialMapSnapshotError: LocalizedError, Equatable {
    case duplicateLandmarkIdentifier(UInt64)
    case nonfiniteLandmark(UInt64)
    case unsupportedSchema(Int)
    case mapIdentifierMismatch
    case invalidBounds
    case landmarkCountMismatch(points: Int, identifiers: Int)

    var errorDescription: String? {
        switch self {
        case .duplicateLandmarkIdentifier(let identifier):
            return "The spatial map contains duplicate landmark ID \(identifier)."
        case .nonfiniteLandmark(let identifier):
            return "Spatial landmark \(identifier) has an invalid position."
        case .unsupportedSchema(let version):
            return "Spatial map schema \(version) is unsupported."
        case .mapIdentifierMismatch:
            return "The spatial snapshot belongs to another saved map."
        case .invalidBounds:
            return "The spatial snapshot bounds do not match its landmarks."
        case .landmarkCountMismatch(let points, let identifiers):
            return "The spatial map has \(points) positions but \(identifiers) identifiers."
        }
    }
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
    var spatialMapURL: URL { directoryURL.appendingPathComponent("spatial-map.plist") }
    var previewURL: URL { directoryURL.appendingPathComponent("preview.jpg") }
}
