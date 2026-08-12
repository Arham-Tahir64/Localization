import Foundation

struct ValidationRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let mapID: UUID
    let mapName: String
    let startedAt: Date
    let completedAt: Date
    let outcome: ValidationOutcome
    let startTrackingLabel: String
    let endTrackingLabel: String
    let startConfidenceLabel: String
    let endConfidenceLabel: String
    let finalPosition: ValidationPosition?
    let finalOrientation: ValidationOrientation?
    let notes: String?
    let benchmark: SessionBenchmarkReport?

    init(
        id: UUID = UUID(),
        mapID: UUID,
        mapName: String,
        startedAt: Date,
        completedAt: Date,
        outcome: ValidationOutcome,
        startTrackingLabel: String,
        endTrackingLabel: String,
        startConfidenceLabel: String,
        endConfidenceLabel: String,
        finalPosition: ValidationPosition? = nil,
        finalOrientation: ValidationOrientation? = nil,
        notes: String? = nil,
        benchmark: SessionBenchmarkReport? = nil
    ) {
        self.id = id
        self.mapID = mapID
        self.mapName = mapName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.startTrackingLabel = startTrackingLabel
        self.endTrackingLabel = endTrackingLabel
        self.startConfidenceLabel = startConfidenceLabel
        self.endConfidenceLabel = endConfidenceLabel
        self.finalPosition = finalPosition
        self.finalOrientation = finalOrientation
        self.notes = notes
        self.benchmark = benchmark
    }

    var duration: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }
}

enum BenchmarkSessionMode: String, Codable, Hashable, Sendable {
    case mapping
    case relocalization
}

enum TrackingBenchmarkCategory: String, Codable, Hashable, Sendable {
    case normal
    case limitedInitializing
    case limitedExcessiveMotion
    case limitedInsufficientFeatures
    case limitedRelocalizing
    case limitedOther
    case unavailable
}

struct SessionRuntimeMetrics: Codable, Hashable, Sendable {
    let frameCount: Int
    let cameraWidth: Int
    let cameraHeight: Int
    let effectiveFramesPerSecond: Double
    let trackingSampleCounts: [String: Int]

    init(
        frameCount: Int,
        cameraWidth: Int,
        cameraHeight: Int,
        effectiveFramesPerSecond: Double,
        trackingSampleCounts: [TrackingBenchmarkCategory: Int]
    ) {
        self.frameCount = frameCount
        self.cameraWidth = cameraWidth
        self.cameraHeight = cameraHeight
        self.effectiveFramesPerSecond = effectiveFramesPerSecond
        self.trackingSampleCounts = Dictionary(
            uniqueKeysWithValues: trackingSampleCounts.map { ($0.key.rawValue, $0.value) }
        )
    }

    func trackingSampleCount(for category: TrackingBenchmarkCategory) -> Int {
        trackingSampleCounts[category.rawValue, default: 0]
    }
}

struct FeatureBenchmarkMetrics: Codable, Hashable, Sendable {
    let sampleCount: Int
    let meanObservedCount: Double
    let maximumObservedCount: Int
    let meanVisibleCount: Double
    let maximumVisibleCount: Int
    let meanDisplayedCount: Double
    let maximumDisplayedCount: Int
    let displayCappedSampleCount: Int
    let meanRejectedBehindCameraCount: Double
    let meanRejectedInvalidProjectionCount: Double
    let meanRejectedOutsideViewportCount: Double
    let meanMapIdentityMatchCount: Double
    let maximumMapIdentityMatchCount: Int
}

struct DepthBenchmarkMetrics: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let highConfidenceFraction: Double?
}

struct MapBenchmarkMetrics: Codable, Hashable, Sendable {
    let mapID: UUID
    let mapName: String
    let landmarkCount: Int
    let meshAnchorCount: Int
    let meshVertexCount: Int
    let meshTriangleCount: Int
    let spatialMapByteCount: Int?
    let packageByteCount: Int64?
    let ioDuration: TimeInterval?
}

struct SessionBenchmarkReport: Codable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionID: UUID
    let mode: BenchmarkSessionMode
    let startedAt: Date
    let completedAt: Date
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    let runtime: SessionRuntimeMetrics
    let features: FeatureBenchmarkMetrics?
    let depth: DepthBenchmarkMetrics?
    let map: MapBenchmarkMetrics?

    var id: UUID { sessionID }

    init(
        schemaVersion: Int = currentSchemaVersion,
        sessionID: UUID,
        mode: BenchmarkSessionMode,
        startedAt: Date,
        completedAt: Date,
        deviceModel: String,
        systemVersion: String,
        appVersion: String,
        runtime: SessionRuntimeMetrics,
        features: FeatureBenchmarkMetrics?,
        depth: DepthBenchmarkMetrics?,
        map: MapBenchmarkMetrics?
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.mode = mode
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.runtime = runtime
        self.features = features
        self.depth = depth
        self.map = map
    }

    var duration: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct SessionBenchmarkAccumulator: Sendable {
    let sessionID: UUID
    let startedAt: Date

    private var frameCount = 0
    private var firstFrameTimestamp: TimeInterval?
    private var lastFrameTimestamp: TimeInterval?
    private var cameraWidth = 0
    private var cameraHeight = 0
    private var trackingSampleCounts: [TrackingBenchmarkCategory: Int] = [:]

    private var featureSampleCount = 0
    private var observedTotal = 0
    private var maximumObservedCount = 0
    private var visibleTotal = 0
    private var maximumVisibleCount = 0
    private var displayedTotal = 0
    private var maximumDisplayedCount = 0
    private var displayCappedSampleCount = 0
    private var rejectedBehindTotal = 0
    private var rejectedInvalidProjectionTotal = 0
    private var rejectedOutsideTotal = 0
    private var identityMatchTotal = 0
    private var maximumIdentityMatchCount = 0
    private var latestDepth: DepthBenchmarkMetrics?
    private var mapMetrics: MapBenchmarkMetrics?

    init(sessionID: UUID = UUID(), startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }

    mutating func recordFrame(
        timestamp: TimeInterval,
        cameraWidth: Int,
        cameraHeight: Int,
        trackingCategory: TrackingBenchmarkCategory
    ) {
        guard timestamp.isFinite, cameraWidth > 0, cameraHeight > 0 else { return }
        frameCount += 1
        if firstFrameTimestamp == nil { firstFrameTimestamp = timestamp }
        if let lastFrameTimestamp, timestamp <= lastFrameTimestamp {
            firstFrameTimestamp = timestamp
            frameCount = 1
        }
        lastFrameTimestamp = timestamp
        self.cameraWidth = cameraWidth
        self.cameraHeight = cameraHeight
        trackingSampleCounts[trackingCategory, default: 0] += 1
    }

    mutating func recordFeatureSnapshot(_ snapshot: FeaturePointSnapshot) {
        featureSampleCount += 1
        observedTotal += snapshot.observedCount
        maximumObservedCount = max(maximumObservedCount, snapshot.observedCount)
        visibleTotal += snapshot.visibleCount
        maximumVisibleCount = max(maximumVisibleCount, snapshot.visibleCount)
        displayedTotal += snapshot.displayedCount
        maximumDisplayedCount = max(maximumDisplayedCount, snapshot.displayedCount)
        if snapshot.displayedCount < snapshot.visibleCount { displayCappedSampleCount += 1 }
        rejectedBehindTotal += snapshot.rejectedBehindCameraCount
        rejectedInvalidProjectionTotal += snapshot.rejectedInvalidProjectionCount
        rejectedOutsideTotal += snapshot.rejectedOutsideViewportCount
        identityMatchTotal += snapshot.mapIdentityMatchCount
        maximumIdentityMatchCount = max(maximumIdentityMatchCount, snapshot.mapIdentityMatchCount)
    }

    mutating func recordDepth(_ metrics: DepthBenchmarkMetrics) {
        latestDepth = metrics
    }

    mutating func recordMap(_ metrics: MapBenchmarkMetrics) {
        mapMetrics = metrics
    }

    func makeReport(
        mode: BenchmarkSessionMode,
        completedAt: Date,
        deviceModel: String,
        systemVersion: String,
        appVersion: String
    ) -> SessionBenchmarkReport {
        let elapsedFrames = max(0, (lastFrameTimestamp ?? 0) - (firstFrameTimestamp ?? 0))
        let effectiveFPS = elapsedFrames > 0 && frameCount > 1
            ? Double(frameCount - 1) / elapsedFrames
            : 0
        let runtime = SessionRuntimeMetrics(
            frameCount: frameCount,
            cameraWidth: cameraWidth,
            cameraHeight: cameraHeight,
            effectiveFramesPerSecond: effectiveFPS,
            trackingSampleCounts: trackingSampleCounts
        )
        let features: FeatureBenchmarkMetrics?
        if featureSampleCount > 0 {
            let divisor = Double(featureSampleCount)
            features = FeatureBenchmarkMetrics(
                sampleCount: featureSampleCount,
                meanObservedCount: Double(observedTotal) / divisor,
                maximumObservedCount: maximumObservedCount,
                meanVisibleCount: Double(visibleTotal) / divisor,
                maximumVisibleCount: maximumVisibleCount,
                meanDisplayedCount: Double(displayedTotal) / divisor,
                maximumDisplayedCount: maximumDisplayedCount,
                displayCappedSampleCount: displayCappedSampleCount,
                meanRejectedBehindCameraCount: Double(rejectedBehindTotal) / divisor,
                meanRejectedInvalidProjectionCount: Double(rejectedInvalidProjectionTotal) / divisor,
                meanRejectedOutsideViewportCount: Double(rejectedOutsideTotal) / divisor,
                meanMapIdentityMatchCount: Double(identityMatchTotal) / divisor,
                maximumMapIdentityMatchCount: maximumIdentityMatchCount
            )
        } else {
            features = nil
        }
        return SessionBenchmarkReport(
            sessionID: sessionID,
            mode: mode,
            startedAt: startedAt,
            completedAt: completedAt,
            deviceModel: deviceModel,
            systemVersion: systemVersion,
            appVersion: appVersion,
            runtime: runtime,
            features: features,
            depth: latestDepth,
            map: mapMetrics
        )
    }
}

enum ValidationOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case timeout
    case cancelled
    case sessionFailure

    var title: String {
        switch self {
        case .success: return "Success"
        case .timeout: return "Timed out"
        case .cancelled: return "Cancelled"
        case .sessionFailure: return "Session failure"
        }
    }

    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .cancelled: return "xmark.circle"
        case .sessionFailure: return "exclamationmark.triangle.fill"
        }
    }
}

struct ValidationPosition: Codable, Hashable, Sendable {
    let x: Float
    let y: Float
    let z: Float
}

struct ValidationOrientation: Codable, Hashable, Sendable {
    let pitch: Float
    let yaw: Float
    let roll: Float
}
