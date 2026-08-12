import Foundation
import simd

/// Versioned metadata paired with one encoded camera frame sent to a localizer.
/// Media bytes travel separately and are joined only by `sessionID` + `frameID`.
struct FrameObservationEnvelope: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let map: ServerMapReference
    let sessionID: UUID
    let frameID: UInt64
    let capturedAt: TimeInterval
    let image: EncodedImageGeometry
    let intrinsics: Matrix3x3Record
    let worldFromCamera: Matrix4x4Record
    let tracking: ObservationTrackingState
    let depth: DepthObservationMetadata?

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FrameObservationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard capturedAt.isFinite, capturedAt >= 0 else {
            throw FrameObservationError.invalidCaptureTime
        }
        try image.validate()
        try intrinsics.validateCameraIntrinsics()
        try worldFromCamera.validateRigidTransform()
        try depth?.validate()
    }
}

struct ServerMapReference: Codable, Hashable, Sendable {
    let mapID: UUID
    let versionID: UUID
}

struct PendingMappingKeyframe: Hashable, Sendable {
    let id: UUID
    let frameID: UInt64
    let capturedAt: TimeInterval
    let image: EncodedImageGeometry
    let intrinsics: Matrix3x3Record
    let mapFromCamera: Matrix4x4Record
    let tracking: ObservationTrackingState
    let sourceFeatureCount: Int
    let imageData: Data
}

struct MappingKeyframeRecord: Codable, Hashable, Sendable {
    let id: UUID
    let frameID: UInt64
    let capturedAt: TimeInterval
    let image: EncodedImageGeometry
    let intrinsics: Matrix3x3Record
    let mapFromCamera: Matrix4x4Record
    let tracking: ObservationTrackingState
    let sourceFeatureCount: Int
    let imageFileName: String

    func validate() throws {
        guard capturedAt.isFinite, capturedAt >= 0 else {
            throw MappingKeyframeError.invalidCaptureTime
        }
        try image.validate()
        try intrinsics.validateCameraIntrinsics()
        try mapFromCamera.validateRigidTransform()
        guard tracking == .normal else {
            throw MappingKeyframeError.invalidTrackingState
        }
        guard sourceFeatureCount >= 0 else {
            throw MappingKeyframeError.invalidFeatureCount
        }
        guard imageFileName == "\(id.uuidString).jpg" else {
            throw MappingKeyframeError.invalidImageFileName
        }
    }
}

struct MappingKeyframeManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mapID: UUID
    let keyframes: [MappingKeyframeRecord]

    init(mapID: UUID, captures: [PendingMappingKeyframe]) throws {
        var identifiers: Set<UUID> = []
        var frameIdentifiers: Set<UInt64> = []
        let records = try captures.map { capture in
            guard !capture.imageData.isEmpty else {
                throw MappingKeyframeError.emptyImage(capture.id)
            }
            guard identifiers.insert(capture.id).inserted else {
                throw MappingKeyframeError.duplicateIdentifier(capture.id)
            }
            guard frameIdentifiers.insert(capture.frameID).inserted else {
                throw MappingKeyframeError.duplicateFrameIdentifier(capture.frameID)
            }
            let record = MappingKeyframeRecord(
                id: capture.id,
                frameID: capture.frameID,
                capturedAt: capture.capturedAt,
                image: capture.image,
                intrinsics: capture.intrinsics,
                mapFromCamera: capture.mapFromCamera,
                tracking: capture.tracking,
                sourceFeatureCount: capture.sourceFeatureCount,
                imageFileName: "\(capture.id.uuidString).jpg"
            )
            try record.validate()
            return record
        }
        schemaVersion = Self.currentSchemaVersion
        self.mapID = mapID
        keyframes = records.sorted { lhs, rhs in
            lhs.capturedAt == rhs.capturedAt
                ? lhs.frameID < rhs.frameID
                : lhs.capturedAt < rhs.capturedAt
        }
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data, expectedMapID: UUID) throws -> MappingKeyframeManifest {
        let decoded = try JSONDecoder().decode(MappingKeyframeManifest.self, from: data)
        guard decoded.schemaVersion == currentSchemaVersion else {
            throw MappingKeyframeError.unsupportedSchema(decoded.schemaVersion)
        }
        guard decoded.mapID == expectedMapID else {
            throw MappingKeyframeError.mapIdentifierMismatch
        }
        var identifiers: Set<UUID> = []
        var frameIdentifiers: Set<UInt64> = []
        for record in decoded.keyframes {
            guard identifiers.insert(record.id).inserted else {
                throw MappingKeyframeError.duplicateIdentifier(record.id)
            }
            guard frameIdentifiers.insert(record.frameID).inserted else {
                throw MappingKeyframeError.duplicateFrameIdentifier(record.frameID)
            }
            try record.validate()
        }
        return decoded
    }
}

struct MappingKeyframeSelector: Sendable {
    let minimumTranslationMeters: Float
    let minimumRotationRadians: Float
    let minimumTimeInterval: TimeInterval
    let minimumFeatureCount: Int
    let maximumKeyframeCount: Int

    private(set) var reservedCount = 0
    private var previousTimestamp: TimeInterval?
    private var previousMapFromCamera: simd_float4x4?
    private var pendingRollbackState: (timestamp: TimeInterval?, mapFromCamera: simd_float4x4?)?

    init(
        minimumTranslationMeters: Float = 0.45,
        minimumRotationRadians: Float = 25 * .pi / 180,
        minimumTimeInterval: TimeInterval = 0.75,
        // This is only a capture-health floor. The desktop builder applies the
        // actual ALIKED/LightGlue/triangulation gates, so do not require the
        // unrelated public ARKit sparse cloud to already be dense.
        minimumFeatureCount: Int = 80,
        maximumKeyframeCount: Int = 120
    ) {
        self.minimumTranslationMeters = max(0, minimumTranslationMeters)
        self.minimumRotationRadians = max(0, minimumRotationRadians)
        self.minimumTimeInterval = max(0, minimumTimeInterval)
        self.minimumFeatureCount = max(0, minimumFeatureCount)
        self.maximumKeyframeCount = max(0, maximumKeyframeCount)
    }

    mutating func reserveIfEligible(
        timestamp: TimeInterval,
        mapFromCamera: simd_float4x4,
        tracking: ObservationTrackingState,
        featureCount: Int
    ) -> Bool {
        guard pendingRollbackState == nil,
              reservedCount < maximumKeyframeCount,
              timestamp.isFinite,
              timestamp >= 0,
              tracking == .normal,
              featureCount >= minimumFeatureCount,
              (try? Matrix4x4Record(mapFromCamera).validateRigidTransform()) != nil else {
            return false
        }
        if let previousTimestamp,
           timestamp - previousTimestamp < minimumTimeInterval {
            return false
        }
        if let previousMapFromCamera {
            let oldPosition = SIMD3(previousMapFromCamera.columns.3.x, previousMapFromCamera.columns.3.y, previousMapFromCamera.columns.3.z)
            let newPosition = SIMD3(mapFromCamera.columns.3.x, mapFromCamera.columns.3.y, mapFromCamera.columns.3.z)
            let translation = simd_distance(oldPosition, newPosition)
            let oldRotation = simd_quatf(previousMapFromCamera)
            let newRotation = simd_quatf(mapFromCamera)
            let cosineHalfAngle = min(1, max(0, abs(simd_dot(oldRotation.vector, newRotation.vector))))
            let rotation = 2 * acos(cosineHalfAngle)
            guard translation >= minimumTranslationMeters || rotation >= minimumRotationRadians else {
                return false
            }
        }
        pendingRollbackState = (
            timestamp: previousTimestamp,
            mapFromCamera: previousMapFromCamera
        )
        previousTimestamp = timestamp
        previousMapFromCamera = mapFromCamera
        reservedCount += 1
        return true
    }

    mutating func cancelMostRecentReservation() {
        guard reservedCount > 0, let rollback = pendingRollbackState else { return }
        previousTimestamp = rollback.timestamp
        previousMapFromCamera = rollback.mapFromCamera
        reservedCount -= 1
        pendingRollbackState = nil
    }

    mutating func commitMostRecentReservation() {
        pendingRollbackState = nil
    }
}

struct EncodedImageGeometry: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let orientation: EncodedImageOrientation
    let camera: CameraSelection

    func validate() throws {
        guard width > 0, height > 0 else {
            throw FrameObservationError.invalidImageDimensions
        }
    }
}

enum EncodedImageOrientation: String, Codable, Hashable, Sendable {
    case up
    case upMirrored
    case down
    case downMirrored
    case left
    case leftMirrored
    case right
    case rightMirrored
}

enum CameraSelection: String, Codable, Hashable, Sendable {
    case rearWide
    case rearUltraWide
    case rearTelephoto
}

enum ObservationTrackingState: String, Codable, Hashable, Sendable {
    case normal
    case limitedInitializing
    case limitedExcessiveMotion
    case limitedInsufficientFeatures
    case limitedRelocalizing
    case limitedOther
    case unavailable
}

struct DepthObservationMetadata: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let format: DepthFormat
    let confidenceIncluded: Bool
    let imageFromDepth: Matrix3x3Record

    func validate() throws {
        guard width > 0, height > 0 else {
            throw FrameObservationError.invalidDepthDimensions
        }
        try imageFromDepth.validateFinite()
    }
}

enum DepthFormat: String, Codable, Hashable, Sendable {
    case float16Meters
    case float32Meters
}

struct Matrix3x3Record: Codable, Hashable, Sendable {
    /// Column-major values, matching simd and ARKit matrix layout.
    let values: [Float]

    init(values: [Float]) {
        self.values = values
    }

    init(_ matrix: simd_float3x3) {
        values = (0..<3).flatMap { column in
            (0..<3).map { row in matrix[column][row] }
        }
    }

    func simdMatrix() throws -> simd_float3x3 {
        try validateFinite()
        return simd_float3x3(
            SIMD3(values[0], values[1], values[2]),
            SIMD3(values[3], values[4], values[5]),
            SIMD3(values[6], values[7], values[8])
        )
    }

    func validateFinite() throws {
        guard values.count == 9, values.allSatisfy(\.isFinite) else {
            throw FrameObservationError.invalidMatrix
        }
    }

    func validateCameraIntrinsics() throws {
        try validateFinite()
        let fx = values[0]
        let fy = values[4]
        guard fx > 0, fy > 0 else {
            throw FrameObservationError.invalidCameraIntrinsics
        }
    }
}

struct Matrix4x4Record: Codable, Hashable, Sendable {
    /// Column-major values, matching simd and ARKit matrix layout.
    let values: [Float]

    init(values: [Float]) {
        self.values = values
    }

    init(_ matrix: simd_float4x4) {
        values = (0..<4).flatMap { column in
            (0..<4).map { row in matrix[column][row] }
        }
    }

    func simdMatrix() throws -> simd_float4x4 {
        try validateRigidTransform()
        return simd_float4x4(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )
    }

    func validateRigidTransform() throws {
        guard values.count == 16, values.allSatisfy(\.isFinite) else {
            throw FrameObservationError.invalidMatrix
        }
        let tolerance: Float = 0.0001
        guard abs(values[3]) <= tolerance,
              abs(values[7]) <= tolerance,
              abs(values[11]) <= tolerance,
              abs(values[15] - 1) <= tolerance else {
            throw FrameObservationError.invalidRigidTransform
        }

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
              simd_dot(simd_cross(x, y), z) > 0 else {
            throw FrameObservationError.invalidRigidTransform
        }
    }
}

struct ServerLocalizationResult: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let map: ServerMapReference
    let sessionID: UUID
    let frameID: UInt64
    let capturedAt: TimeInterval
    let mapFromCamera: Matrix4x4Record
    let verification: ServerVerificationMode
    let quality: LocalizationQualityRecord

    /// Establishes `T_M_W = T_M_C · inverse(T_W_C)` for the exact query frame.
    func mapFromWorld(for observation: FrameObservationEnvelope) throws -> simd_float4x4 {
        try observation.validate()
        try validate()
        guard map == observation.map else {
            throw FrameObservationError.mapVersionMismatch
        }
        guard sessionID == observation.sessionID else {
            throw FrameObservationError.sessionMismatch
        }
        guard frameID == observation.frameID, capturedAt == observation.capturedAt else {
            throw FrameObservationError.frameMismatch
        }
        return CoordinateFrames.mapFromWorld(
            globalMapFromCamera: try mapFromCamera.simdMatrix(),
            worldFromCameraAtMatch: try observation.worldFromCamera.simdMatrix()
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FrameObservationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard capturedAt.isFinite, capturedAt >= 0 else {
            throw FrameObservationError.invalidCaptureTime
        }
        try mapFromCamera.validateRigidTransform()
        try quality.validate()
    }
}

enum ServerVerificationMode: String, Codable, Hashable, Sendable {
    case visualPnP
    case visualAndDepth
}

struct LocalizationQualityRecord: Codable, Hashable, Sendable {
    let inlierCount: Int
    let inlierRatio: Float
    let medianReprojectionErrorPixels: Float
    let depthOverlapRatio: Float?
    let depthRMSEMeters: Float?

    func validate() throws {
        guard inlierCount >= 0,
              inlierRatio.isFinite,
              (0...1).contains(inlierRatio),
              medianReprojectionErrorPixels.isFinite,
              medianReprojectionErrorPixels >= 0 else {
            throw FrameObservationError.invalidQuality
        }
        if let depthOverlapRatio {
            guard depthOverlapRatio.isFinite, (0...1).contains(depthOverlapRatio) else {
                throw FrameObservationError.invalidQuality
            }
        }
        if let depthRMSEMeters {
            guard depthRMSEMeters.isFinite, depthRMSEMeters >= 0 else {
                throw FrameObservationError.invalidQuality
            }
        }
    }
}

enum FrameObservationError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidCaptureTime
    case invalidImageDimensions
    case invalidDepthDimensions
    case invalidMatrix
    case invalidRigidTransform
    case invalidCameraIntrinsics
    case invalidQuality
    case mapVersionMismatch
    case sessionMismatch
    case frameMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Observation schema version \(version) is unsupported."
        case .invalidCaptureTime:
            return "The observation capture time is invalid."
        case .invalidImageDimensions:
            return "The encoded image dimensions are invalid."
        case .invalidDepthDimensions:
            return "The depth dimensions are invalid."
        case .invalidMatrix:
            return "A matrix has an invalid shape or non-finite value."
        case .invalidRigidTransform:
            return "A pose matrix is not a homogeneous rigid transform."
        case .invalidCameraIntrinsics:
            return "The camera intrinsics are invalid."
        case .invalidQuality:
            return "The localization quality diagnostics are invalid."
        case .mapVersionMismatch:
            return "The localization result belongs to a different map version."
        case .sessionMismatch:
            return "The localization result belongs to a previous AR session."
        case .frameMismatch:
            return "The localization result does not match the submitted frame."
        }
    }
}

enum MappingKeyframeError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case mapIdentifierMismatch
    case duplicateIdentifier(UUID)
    case duplicateFrameIdentifier(UInt64)
    case emptyImage(UUID)
    case invalidCaptureTime
    case invalidTrackingState
    case invalidFeatureCount
    case invalidImageFileName

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Keyframe manifest schema \(version) is unsupported."
        case .mapIdentifierMismatch:
            return "The keyframe manifest belongs to another saved map."
        case .duplicateIdentifier(let id):
            return "The keyframe manifest contains duplicate keyframe \(id)."
        case .duplicateFrameIdentifier(let frameID):
            return "The keyframe manifest contains duplicate frame \(frameID)."
        case .emptyImage(let id):
            return "Keyframe \(id) has no encoded camera image."
        case .invalidCaptureTime:
            return "A keyframe capture timestamp is invalid."
        case .invalidTrackingState:
            return "A mapping keyframe was captured without normal tracking."
        case .invalidFeatureCount:
            return "A keyframe feature count is invalid."
        case .invalidImageFileName:
            return "A keyframe image file name is invalid."
        }
    }
}
