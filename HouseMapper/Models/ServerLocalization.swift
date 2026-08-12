import Foundation
import simd

struct ServerModelIdentity: Codable, Hashable, Sendable {
    let reconstruction: String
    let retrieval: String
    let localFeatures: String
    let matcher: String

    func validate() throws {
        for value in [reconstruction, retrieval, localFeatures, matcher] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 120 else {
                throw ServerMapManifestError.invalidModelIdentity
            }
        }
    }
}

struct ServerQueryConfiguration: Codable, Hashable, Sendable {
    let maximumImageWidth: Int
    let jpegQuality: Float
    let minimumQueryInterval: TimeInterval
    let requestTimeout: TimeInterval

    func validate() throws {
        guard (320...1_920).contains(maximumImageWidth),
              jpegQuality.isFinite,
              (0.4...0.95).contains(jpegQuality),
              minimumQueryInterval.isFinite,
              (0.25...5).contains(minimumQueryInterval),
              requestTimeout.isFinite,
              (1...30).contains(requestTimeout) else {
            throw ServerMapManifestError.invalidQueryConfiguration
        }
    }
}

struct ServerMapManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let metricFrameConvention = "T_map_camera-right-handed-y-up-meters"

    let schemaVersion: Int
    let map: ServerMapReference
    let createdAt: Date
    let queryEndpoint: String
    let frameConvention: String
    let models: ServerModelIdentity
    let query: ServerQueryConfiguration

    init(
        schemaVersion: Int = currentSchemaVersion,
        map: ServerMapReference,
        createdAt: Date,
        queryEndpoint: String,
        frameConvention: String = metricFrameConvention,
        models: ServerModelIdentity,
        query: ServerQueryConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.map = map
        self.createdAt = createdAt
        self.queryEndpoint = queryEndpoint
        self.frameConvention = frameConvention
        self.models = models
        self.query = query
    }

    func validate(expectedMapID: UUID) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ServerMapManifestError.unsupportedSchema(schemaVersion)
        }
        guard map.mapID == expectedMapID else {
            throw ServerMapManifestError.mapIdentifierMismatch
        }
        guard frameConvention == Self.metricFrameConvention else {
            throw ServerMapManifestError.incompatibleFrameConvention
        }
        guard createdAt.timeIntervalSince1970.isFinite else {
            throw ServerMapManifestError.invalidCreationDate
        }
        guard let endpoint = URL(string: queryEndpoint),
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              let scheme = endpoint.scheme?.lowercased(),
              let host = endpoint.host?.lowercased(),
              !host.isEmpty else {
            throw ServerMapManifestError.invalidEndpoint
        }
        guard scheme == "https" || (scheme == "http" && host.hasSuffix(".local")) else {
            throw ServerMapManifestError.insecureEndpoint
        }
        try models.validate()
        try query.validate()
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data, expectedMapID: UUID) throws -> ServerMapManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ServerMapManifest.self, from: data)
        try decoded.validate(expectedMapID: expectedMapID)
        return decoded
    }
}

struct ServerImagePoint: Codable, Hashable, Sendable {
    let x: Float
    let y: Float
    let mapLandmarkID: UInt64
    let mapPosition: Vector3Record

    func validate(in image: EncodedImageGeometry) throws {
        guard x.isFinite,
              y.isFinite,
              x >= 0,
              y >= 0,
              x < Float(image.width),
              y < Float(image.height),
              mapPosition.x.isFinite,
              mapPosition.y.isFinite,
              mapPosition.z.isFinite else {
            throw ServerLocalizationContractError.invalidInlierPoint
        }
    }
}

struct ServerLocalizationResponse: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let result: ServerLocalizationResult
    /// Verified PnP inliers in encoded native-image pixels.
    let inliers: [ServerImagePoint]

    func validate(for observation: FrameObservationEnvelope) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ServerLocalizationContractError.unsupportedSchema(schemaVersion)
        }
        _ = try result.mapFromWorld(for: observation)
        guard !inliers.isEmpty,
              inliers.count <= result.quality.inlierCount else {
            throw ServerLocalizationContractError.inlierCountMismatch
        }
        guard Set(inliers.map(\.mapLandmarkID)).count == inliers.count else {
            throw ServerLocalizationContractError.duplicateInlierLandmark
        }
        let mapFromCamera = try result.mapFromCamera.simdMatrix()
        let cameraFromMap = simd_inverse(mapFromCamera)
        let intrinsics = try observation.intrinsics.simdMatrix()
        var residuals: [Float] = []
        residuals.reserveCapacity(inliers.count)
        for inlier in inliers {
            try inlier.validate(in: observation.image)
            let cameraPoint = simd_mul(
                cameraFromMap,
                SIMD4(
                    inlier.mapPosition.x,
                    inlier.mapPosition.y,
                    inlier.mapPosition.z,
                    1
                )
            )
            guard cameraPoint.z < -0.01 else {
                throw ServerLocalizationContractError.inlierGeometryMismatch
            }
            // ARKit camera coordinates look down -Z. Camera intrinsics use the
            // native pixel convention, so project x/-z and y/-z.
            let normalized = SIMD3(
                cameraPoint.x / -cameraPoint.z,
                -cameraPoint.y / -cameraPoint.z,
                1
            )
            let pixel = simd_mul(intrinsics, normalized)
            guard pixel.z.isFinite, abs(pixel.z) > 0.0001 else {
                throw ServerLocalizationContractError.inlierGeometryMismatch
            }
            let projected = SIMD2(pixel.x / pixel.z, pixel.y / pixel.z)
            let observed = SIMD2(inlier.x, inlier.y)
            let residual = simd_distance(projected, observed)
            guard residual.isFinite, residual <= 8 else {
                throw ServerLocalizationContractError.inlierGeometryMismatch
            }
            residuals.append(residual)
        }
        let sortedResiduals = residuals.sorted()
        let medianResidual = sortedResiduals[sortedResiduals.count / 2]
        guard medianResidual <= 3,
              abs(medianResidual - result.quality.medianReprojectionErrorPixels) <= 1 else {
            throw ServerLocalizationContractError.inlierGeometryMismatch
        }
    }
}

struct ServerLocalizationRequest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let observation: FrameObservationEnvelope
    let jpegImage: Data

    init(observation: FrameObservationEnvelope, jpegImage: Data) throws {
        try observation.validate()
        guard jpegImage.count >= 4,
              jpegImage.starts(with: [0xFF, 0xD8]),
              jpegImage.suffix(2) == Data([0xFF, 0xD9]) else {
            throw ServerLocalizationContractError.emptyImage
        }
        schemaVersion = Self.currentSchemaVersion
        self.observation = observation
        self.jpegImage = jpegImage
    }

    func encodedJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    func validate(response: ServerLocalizationResponse) throws {
        try response.validate(for: observation)
        guard response.result.verification == .visualPnP,
              response.result.quality.depthOverlapRatio == nil,
              response.result.quality.depthRMSEMeters == nil else {
            throw ServerLocalizationContractError.unexpectedDepthVerification
        }
    }
}

actor ServerLocalizationHTTPClient {
    static let maximumRequestByteCount = 12 * 1_024 * 1_024
    static let maximumResponseByteCount = 2 * 1_024 * 1_024

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func localize(
        request localizationRequest: ServerLocalizationRequest,
        manifest: ServerMapManifest
    ) async throws -> ServerLocalizationResponse {
        try manifest.validate(expectedMapID: localizationRequest.observation.map.mapID)
        guard manifest.map == localizationRequest.observation.map,
              let endpoint = URL(string: manifest.queryEndpoint) else {
            throw ServerLocalizationTransportError.mapVersionMismatch
        }
        let body = try localizationRequest.encodedJSON()
        guard body.count <= Self.maximumRequestByteCount else {
            throw ServerLocalizationTransportError.requestTooLarge
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = manifest.query.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: ServerLocalizationNoRedirectDelegate.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw ServerLocalizationTransportError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ServerLocalizationTransportError.httpStatus(http.statusCode)
        }
        guard let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased(),
              contentType.hasPrefix("application/json") else {
            throw ServerLocalizationTransportError.invalidResponse
        }
        var data = Data()
        let advertisedLength = response.expectedContentLength
        if advertisedLength > Int64(Self.maximumResponseByteCount) {
            throw ServerLocalizationTransportError.responseTooLarge
        }
        if advertisedLength > 0 {
            data.reserveCapacity(Int(advertisedLength))
        }
        for try await byte in bytes {
            guard data.count < Self.maximumResponseByteCount else {
                throw ServerLocalizationTransportError.responseTooLarge
            }
            data.append(byte)
        }
        let decoded: ServerLocalizationResponse
        do {
            decoded = try JSONDecoder().decode(ServerLocalizationResponse.self, from: data)
        } catch {
            throw ServerLocalizationTransportError.invalidResponse
        }
        try localizationRequest.validate(response: decoded)
        return decoded
    }
}

private final class ServerLocalizationNoRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    static let shared = ServerLocalizationNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct ServerLocalizationAcceptancePolicy: Hashable, Sendable {
    let minimumInlierCount: Int
    let minimumInlierRatio: Float
    let maximumMedianReprojectionErrorPixels: Float
    let minimumDepthOverlapRatio: Float
    let maximumDepthRMSEMeters: Float

    init(
        minimumInlierCount: Int = 40,
        minimumInlierRatio: Float = 0.25,
        maximumMedianReprojectionErrorPixels: Float = 3,
        minimumDepthOverlapRatio: Float = 0.2,
        maximumDepthRMSEMeters: Float = 0.15
    ) {
        self.minimumInlierCount = minimumInlierCount
        self.minimumInlierRatio = minimumInlierRatio
        self.maximumMedianReprojectionErrorPixels = maximumMedianReprojectionErrorPixels
        self.minimumDepthOverlapRatio = minimumDepthOverlapRatio
        self.maximumDepthRMSEMeters = maximumDepthRMSEMeters
    }

    func accepts(_ response: ServerLocalizationResponse) -> Bool {
        let quality = response.result.quality
        guard quality.inlierCount >= minimumInlierCount,
              quality.inlierRatio >= minimumInlierRatio,
              quality.medianReprojectionErrorPixels <= maximumMedianReprojectionErrorPixels,
              response.inliers.count >= minimumInlierCount else { return false }
        switch response.result.verification {
        case .visualPnP:
            return true
        case .visualAndDepth:
            guard let overlap = quality.depthOverlapRatio,
                  let rmse = quality.depthRMSEMeters else { return false }
            return overlap >= minimumDepthOverlapRatio && rmse <= maximumDepthRMSEMeters
        }
    }
}

struct ServerPoseConfirmationGate: Sendable {
    let requiredConsistentResults: Int
    let maximumTranslationDeltaMeters: Float
    let maximumRotationDeltaRadians: Float
    let maximumCaptureInterval: TimeInterval

    private var previousMapFromWorld: simd_float4x4?
    private var previousFrameID: UInt64?
    private var previousCapturedAt: TimeInterval?
    private(set) var consistentResultCount = 0

    init(
        requiredConsistentResults: Int = 2,
        maximumTranslationDeltaMeters: Float = 0.25,
        maximumRotationDeltaRadians: Float = 10 * .pi / 180,
        maximumCaptureInterval: TimeInterval = 6
    ) {
        self.requiredConsistentResults = max(1, requiredConsistentResults)
        self.maximumTranslationDeltaMeters = max(0, maximumTranslationDeltaMeters)
        self.maximumRotationDeltaRadians = max(0, maximumRotationDeltaRadians)
        self.maximumCaptureInterval = max(0, maximumCaptureInterval)
    }

    mutating func consider(
        response: ServerLocalizationResponse,
        observation: FrameObservationEnvelope,
        policy: ServerLocalizationAcceptancePolicy
    ) throws -> simd_float4x4? {
        try response.validate(for: observation)
        guard policy.accepts(response) else {
            reset()
            return nil
        }
        let candidate = try response.result.mapFromWorld(for: observation)
        if let previousFrameID, observation.frameID <= previousFrameID {
            throw ServerLocalizationContractError.nonmonotonicFrame
        }
        if let previousMapFromWorld,
           let previousCapturedAt,
           observation.capturedAt - previousCapturedAt <= maximumCaptureInterval {
            let previousPosition = SIMD3(previousMapFromWorld.columns.3.x, previousMapFromWorld.columns.3.y, previousMapFromWorld.columns.3.z)
            let position = SIMD3(candidate.columns.3.x, candidate.columns.3.y, candidate.columns.3.z)
            let translation = simd_distance(previousPosition, position)
            let previousRotation = simd_quatf(previousMapFromWorld)
            let rotation = simd_quatf(candidate)
            let cosineHalfAngle = min(1, max(0, abs(simd_dot(previousRotation.vector, rotation.vector))))
            let rotationDelta = 2 * acos(cosineHalfAngle)
            consistentResultCount = translation <= maximumTranslationDeltaMeters
                && rotationDelta <= maximumRotationDeltaRadians
                ? consistentResultCount + 1
                : 1
        } else {
            consistentResultCount = 1
        }
        previousMapFromWorld = candidate
        previousFrameID = observation.frameID
        previousCapturedAt = observation.capturedAt
        return consistentResultCount >= requiredConsistentResults ? candidate : nil
    }

    mutating func reset() {
        previousMapFromWorld = nil
        previousFrameID = nil
        previousCapturedAt = nil
        consistentResultCount = 0
    }
}

enum ServerMapManifestError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case mapIdentifierMismatch
    case incompatibleFrameConvention
    case invalidCreationDate
    case invalidEndpoint
    case insecureEndpoint
    case invalidModelIdentity
    case invalidQueryConfiguration

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Server map manifest schema \(version) is unsupported."
        case .mapIdentifierMismatch: return "The server map manifest belongs to another saved map."
        case .incompatibleFrameConvention: return "The server map uses an incompatible coordinate convention."
        case .invalidCreationDate: return "The server map creation date is invalid."
        case .invalidEndpoint: return "The server localization endpoint is invalid."
        case .insecureEndpoint: return "Use HTTPS, or HTTP with a Bonjour .local computer name."
        case .invalidModelIdentity: return "The server model identity is incomplete or invalid."
        case .invalidQueryConfiguration: return "The server query configuration is outside supported bounds."
        }
    }
}

enum ServerLocalizationContractError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case emptyImage
    case invalidInlierPoint
    case inlierCountMismatch
    case duplicateInlierLandmark
    case inlierGeometryMismatch
    case nonmonotonicFrame
    case unexpectedDepthVerification

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Server localization response schema \(version) is unsupported."
        case .emptyImage: return "The localization query contains no camera image."
        case .invalidInlierPoint: return "A verified server inlier is outside the query image."
        case .inlierCountMismatch: return "Server inlier diagnostics do not match the reported quality."
        case .duplicateInlierLandmark: return "The server repeated a map landmark in one PnP inlier set."
        case .inlierGeometryMismatch: return "The server inliers do not reproject through the reported map pose."
        case .nonmonotonicFrame: return "A stale or reordered localization frame was rejected."
        case .unexpectedDepthVerification: return "Schema v1 sent no depth samples, so a depth-verified result was rejected."
        }
    }
}

enum ServerLocalizationTransportError: LocalizedError, Equatable {
    case mapVersionMismatch
    case requestTooLarge
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .mapVersionMismatch: return "The selected server endpoint belongs to another map version."
        case .requestTooLarge: return "The localization camera request is too large."
        case .invalidResponse: return "The localization server returned an invalid response."
        case .httpStatus(let status): return "The localization server returned HTTP \(status)."
        case .responseTooLarge: return "The localization server response exceeded the safety limit."
        }
    }
}
