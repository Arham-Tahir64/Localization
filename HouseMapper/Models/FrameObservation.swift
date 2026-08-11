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
