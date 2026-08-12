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

struct SpatialTransformRecord: Codable, Hashable, Sendable {
    /// Column-major values matching simd and ARKit matrix layout.
    let values: [Float]

    static let identity = SpatialTransformRecord(
        values: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
    )

    init(values: [Float]) {
        self.values = values
    }

    init(_ matrix: simd_float4x4) {
        values = (0..<4).flatMap { column in
            (0..<4).map { row in matrix[column][row] }
        }
    }

    func simdMatrix() -> simd_float4x4? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        let tolerance: Float = 0.0001
        guard abs(values[3]) <= tolerance,
              abs(values[7]) <= tolerance,
              abs(values[11]) <= tolerance,
              abs(values[15] - 1) <= tolerance else { return nil }

        let x = SIMD3(values[0], values[1], values[2])
        let y = SIMD3(values[4], values[5], values[6])
        let z = SIMD3(values[8], values[9], values[10])
        let rotationTolerance: Float = 0.01
        guard abs(simd_length(x) - 1) <= rotationTolerance,
              abs(simd_length(y) - 1) <= rotationTolerance,
              abs(simd_length(z) - 1) <= rotationTolerance,
              abs(simd_dot(x, y)) <= rotationTolerance,
              abs(simd_dot(x, z)) <= rotationTolerance,
              abs(simd_dot(y, z)) <= rotationTolerance,
              simd_dot(simd_cross(x, y), z) > 0 else { return nil }

        return simd_float4x4(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )
    }
}

struct SpatialMeshFaceRecord: Codable, Hashable, Sendable {
    let firstVertexIndex: UInt32
    let secondVertexIndex: UInt32
    let thirdVertexIndex: UInt32
    let classificationRawValue: Int?
}

struct SpatialMeshAnchorRecord: Codable, Hashable, Sendable {
    let id: UUID
    let mapFromAnchor: SpatialTransformRecord
    let vertices: [Vector3Record]
    let normals: [Vector3Record]
    let faces: [SpatialMeshFaceRecord]

    init(
        id: UUID,
        mapFromAnchor: SpatialTransformRecord,
        vertices: [Vector3Record],
        normals: [Vector3Record],
        faces: [SpatialMeshFaceRecord]
    ) throws {
        guard mapFromAnchor.simdMatrix() != nil else {
            throw SpatialMapSnapshotError.invalidMeshTransform(id)
        }
        guard normals.isEmpty || normals.count == vertices.count else {
            throw SpatialMapSnapshotError.meshNormalCountMismatch(
                anchorID: id,
                vertices: vertices.count,
                normals: normals.count
            )
        }
        for (index, vertex) in vertices.enumerated() {
            guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else {
                throw SpatialMapSnapshotError.nonfiniteMeshVertex(anchorID: id, index: index)
            }
        }
        for (index, normal) in normals.enumerated() {
            guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else {
                throw SpatialMapSnapshotError.nonfiniteMeshNormal(anchorID: id, index: index)
            }
        }
        for (index, face) in faces.enumerated() {
            let vertexCount = UInt32(vertices.count)
            guard face.firstVertexIndex < vertexCount,
                  face.secondVertexIndex < vertexCount,
                  face.thirdVertexIndex < vertexCount else {
                throw SpatialMapSnapshotError.meshIndexOutOfRange(anchorID: id, face: index)
            }
            if let classification = face.classificationRawValue,
               !(0...7).contains(classification) {
                throw SpatialMapSnapshotError.invalidMeshClassification(
                    anchorID: id,
                    face: index,
                    rawValue: classification
                )
            }
        }

        self.id = id
        self.mapFromAnchor = mapFromAnchor
        self.vertices = vertices
        self.normals = normals
        self.faces = faces
    }
}

struct SpatialMapSnapshot: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let mapID: UUID
    let landmarks: [SpatialLandmarkRecord]
    let bounds: SpatialBoundsRecord
    let meshAnchors: [SpatialMeshAnchorRecord]

    init(
        mapID: UUID,
        landmarks: [SpatialLandmarkRecord],
        meshAnchors: [SpatialMeshAnchorRecord] = []
    ) throws {
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
        var meshIdentifiers: Set<UUID> = []
        meshIdentifiers.reserveCapacity(meshAnchors.count)
        for meshAnchor in meshAnchors {
            guard meshIdentifiers.insert(meshAnchor.id).inserted else {
                throw SpatialMapSnapshotError.duplicateMeshAnchorIdentifier(meshAnchor.id)
            }
        }

        schemaVersion = Self.currentSchemaVersion
        self.mapID = mapID
        self.landmarks = landmarks
        self.meshAnchors = meshAnchors
        bounds = Self.bounds(for: landmarks, meshAnchors: meshAnchors)
    }

    init(
        mapID: UUID,
        points: [SIMD3<Float>],
        identifiers: [UInt64],
        meshAnchors: [SpatialMeshAnchorRecord] = []
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
            },
            meshAnchors: meshAnchors
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mapID
        case landmarks
        case bounds
        case meshAnchors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        mapID = try container.decode(UUID.self, forKey: .mapID)
        landmarks = try container.decode([SpatialLandmarkRecord].self, forKey: .landmarks)
        bounds = try container.decode(SpatialBoundsRecord.self, forKey: .bounds)
        meshAnchors = try container.decodeIfPresent(
            [SpatialMeshAnchorRecord].self,
            forKey: .meshAnchors
        ) ?? []
    }

    private static func bounds(
        for landmarks: [SpatialLandmarkRecord],
        meshAnchors: [SpatialMeshAnchorRecord]
    ) -> SpatialBoundsRecord {
        var points = landmarks.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
        for anchor in meshAnchors {
            guard let mapFromAnchor = anchor.mapFromAnchor.simdMatrix() else { continue }
            points.append(contentsOf: anchor.vertices.map { vertex in
                let transformed = simd_mul(
                    mapFromAnchor,
                    SIMD4(vertex.x, vertex.y, vertex.z, 1)
                )
                return SIMD3(transformed.x, transformed.y, transformed.z)
            })
        }
        guard let first = points.first else {
            let zero = Vector3Record(x: 0, y: 0, z: 0)
            return SpatialBoundsRecord(minimum: zero, maximum: zero)
        }

        var minimum = first
        var maximum = first
        for point in points.dropFirst() {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        return SpatialBoundsRecord(
            minimum: Vector3Record(x: minimum.x, y: minimum.y, z: minimum.z),
            maximum: Vector3Record(x: maximum.x, y: maximum.y, z: maximum.z)
        )
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
        guard (1...SpatialMapSnapshot.currentSchemaVersion).contains(decoded.schemaVersion) else {
            throw SpatialMapSnapshotError.unsupportedSchema(decoded.schemaVersion)
        }
        guard decoded.mapID == expectedMapID else {
            throw SpatialMapSnapshotError.mapIdentifierMismatch
        }

        let validated = try SpatialMapSnapshot(
            mapID: decoded.mapID,
            landmarks: decoded.landmarks,
            meshAnchors: decoded.meshAnchors.map { mesh in
                try SpatialMeshAnchorRecord(
                    id: mesh.id,
                    mapFromAnchor: mesh.mapFromAnchor,
                    vertices: mesh.vertices,
                    normals: mesh.normals,
                    faces: mesh.faces
                )
            }
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
    case duplicateMeshAnchorIdentifier(UUID)
    case invalidMeshTransform(UUID)
    case meshNormalCountMismatch(anchorID: UUID, vertices: Int, normals: Int)
    case nonfiniteMeshVertex(anchorID: UUID, index: Int)
    case nonfiniteMeshNormal(anchorID: UUID, index: Int)
    case meshIndexOutOfRange(anchorID: UUID, face: Int)
    case invalidMeshClassification(anchorID: UUID, face: Int, rawValue: Int)

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
            return "The spatial snapshot bounds do not match its landmarks and mesh."
        case .landmarkCountMismatch(let points, let identifiers):
            return "The spatial map has \(points) positions but \(identifiers) identifiers."
        case .duplicateMeshAnchorIdentifier(let anchorID):
            return "The spatial map contains duplicate mesh anchor \(anchorID)."
        case .invalidMeshTransform(let anchorID):
            return "Mesh anchor \(anchorID) has an invalid transform."
        case .meshNormalCountMismatch(let anchorID, let vertices, let normals):
            return "Mesh anchor \(anchorID) has \(vertices) vertices but \(normals) normals."
        case .nonfiniteMeshVertex(let anchorID, let index):
            return "Mesh anchor \(anchorID) has an invalid vertex at index \(index)."
        case .nonfiniteMeshNormal(let anchorID, let index):
            return "Mesh anchor \(anchorID) has an invalid normal at index \(index)."
        case .meshIndexOutOfRange(let anchorID, let face):
            return "Mesh anchor \(anchorID) face \(face) references a missing vertex."
        case .invalidMeshClassification(let anchorID, let face, let rawValue):
            return "Mesh anchor \(anchorID) face \(face) has unsupported classification \(rawValue)."
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
    var benchmarkURL: URL { directoryURL.appendingPathComponent("benchmark.json") }
    var keyframesURL: URL { directoryURL.appendingPathComponent("keyframes", isDirectory: true) }
    var keyframeManifestURL: URL { keyframesURL.appendingPathComponent("manifest.json") }
    var serverMapManifestURL: URL { directoryURL.appendingPathComponent("server-map.json") }
}
