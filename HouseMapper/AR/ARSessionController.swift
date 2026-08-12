import ARKit
import Combine
import SceneKit
import SwiftUI
import UIKit

@MainActor
final class ARSessionController: NSObject, ObservableObject {
    static let mapOriginAnchorName = "com.housemapper.map-origin"

    @Published private(set) var phase: LocalizationPhase
    @Published private(set) var confidence: ConfidenceBand = .unavailable
    @Published private(set) var trackingDescription = "Waiting for camera"
    @Published private(set) var mappingDescription = "Not available"
    @Published private(set) var mappingProgress: Double = 0
    @Published private(set) var featurePointCount = 0
    @Published private(set) var featurePointSnapshot = FeaturePointSnapshot.empty
    @Published private(set) var captureDescription = "Measuring camera"
    @Published private(set) var depthDescription = "Waiting for LiDAR"
    @Published private(set) var meshDescription = "Checking support"
    @Published private(set) var pose: CameraPose?
    @Published private(set) var mapRenderSnapshot = SpatialMapRenderSnapshot.empty
    @Published private(set) var meshRenderSnapshot = SpatialMeshRenderSnapshot.empty
    @Published private(set) var trail: [SIMD2<Float>] = []
    @Published private(set) var elapsedRelocalization: TimeInterval = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var savedPackage: MapPackage?
    @Published private(set) var canSave = false
    @Published private(set) var benchmarkReport: SessionBenchmarkReport?

    let mode: ExperienceMode

    private let mapLibrary: MapLibrary
    private weak var sceneView: ARSCNView?
    private var hasStarted = false
    private var hasDepth = false
    private var hasSceneReconstruction = false
    private var originAnchorSeen = false
    private var relocalizationMachine = RelocalizationStateMachine()
    private var relocalizationStartUptime: TimeInterval?
    private var relocalizationTimeoutTask: Task<Void, Never>?
    private var lastDepthInspection = Date.distantPast
    private var lastTrailPosition: SIMD2<Float>?
    private var lastPublishedPoseTimestamp: TimeInterval = -.infinity
    private var lastDiagnosticPublicationTimestamp: TimeInterval = -.infinity
    private var lastFeatureOverlayTimestamp: TimeInterval = -.infinity
    private var lastCoveragePublicationTimestamp: TimeInterval = -.infinity
    private var loadedWorldMap: ARWorldMap?
    private var loadedSpatialMap: SpatialMapSnapshot?
    private var mappingLandmarks = MappingLandmarkAccumulator(
        maximumRetainedLandmarks: 50_000
    )
    private var captureDiagnostics = CaptureDiagnosticsAccumulator()
    private var benchmarkAccumulator = SessionBenchmarkAccumulator(startedAt: Date())
    private var benchmarkMapMetrics: MapBenchmarkMetrics?
    private var savedFeatureIdentifiers: Set<UInt64> = []
    private var lastMeshUpdateByAnchor: [UUID: TimeInterval] = [:]
    private lazy var meshVisualizationMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.18)
        material.isDoubleSided = true
        return material
    }()

    private static let displayPoseInterval: TimeInterval = 1.0 / 15.0
    private static let diagnosticPublicationInterval: TimeInterval = 0.25
    private static let featureOverlayPublicationInterval: TimeInterval = 0.1
    private static let coveragePublicationInterval: TimeInterval = 0.5
    private static let meshUpdateInterval: TimeInterval = 0.2
    private static let timeoutFallbackGrace: TimeInterval = 0.25
    private static let maximumMapRenderPointCount = 4_000
    private static let maximumMapRenderTriangleCount = 1_500
    private static let maximumScreenFeaturePointCount = 240
    private static let maximumPriorityFeaturePointCount = 120

    init(mode: ExperienceMode, mapLibrary: MapLibrary) {
        self.mode = mode
        self.mapLibrary = mapLibrary
        switch mode {
        case .mapping:
            phase = .mapping
        case .relocalization:
            phase = .loading
        }
        super.init()
    }

    func attach(to view: ARSCNView) {
        sceneView = view
        view.session.delegate = self
        view.session.delegateQueue = .main
        view.delegate = self
        view.automaticallyUpdatesLighting = true
        view.antialiasingMode = .multisampling2X
        view.scene = SCNScene()
        view.debugOptions = []
        startIfNeeded()
    }

    func startIfNeeded() {
        guard !hasStarted, let sceneView else { return }
        hasStarted = true
        statusMessage = nil

        guard ARWorldTrackingConfiguration.isSupported else {
            phase = .unsupported
            statusMessage = "World tracking is unavailable on this device."
            return
        }

        switch mode {
        case .mapping:
            let configuration = makeConfiguration(initialWorldMap: nil)
            sceneView.session.run(
                configuration,
                options: [.resetTracking, .removeExistingAnchors]
            )
            let origin = ARAnchor(
                name: Self.mapOriginAnchorName,
                transform: matrix_identity_float4x4
            )
            sceneView.session.add(anchor: origin)
            phase = .mapping

        case .relocalization(let package):
            phase = .loading
            Task { [weak self] in
                guard let self else { return }
                do {
                    let loadStart = ProcessInfo.processInfo.systemUptime
                    let worldMap = try await mapLibrary.loadWorldMap(from: package)
                    let spatialMap = try await mapLibrary.loadSpatialMap(from: package)
                    let storage = try await mapLibrary.benchmarkStorageMetrics(for: package)
                    guard self.hasStarted else { return }
                    self.loadedWorldMap = worldMap
                    self.loadedSpatialMap = spatialMap
                    self.savedFeatureIdentifiers = Set(spatialMap.landmarks.map(\.id))
                    self.mapRenderSnapshot = SpatialMapRenderSnapshot.make(
                        landmarks: spatialMap.landmarks,
                        maximumCount: Self.maximumMapRenderPointCount
                    )
                    self.meshRenderSnapshot = SpatialMeshRenderSnapshot.make(
                        meshAnchors: spatialMap.meshAnchors,
                        maximumTriangleCount: Self.maximumMapRenderTriangleCount
                    )
                    let metrics = Self.makeMapBenchmarkMetrics(
                        package: package,
                        spatialMap: spatialMap,
                        storage: storage,
                        ioDuration: ProcessInfo.processInfo.systemUptime - loadStart
                    )
                    self.benchmarkMapMetrics = metrics
                    self.beginRelocalization(with: worldMap)
                } catch {
                    self.phase = .failed
                    self.confidence = .unavailable
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func retryRelocalization() {
        guard case .relocalization = mode, let worldMap = loadedWorldMap else { return }
        beginRelocalization(with: worldMap)
    }

    func stop() {
        hasStarted = false
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        sceneView?.session.pause()
    }

    func saveMap(named rawName: String) async {
        guard case .mapping = mode,
              canSave,
              !isSaving,
              let sceneView else { return }

        isSaving = true
        statusMessage = "Capturing persistent world map…"
        let persistenceStart = ProcessInfo.processInfo.systemUptime

        do {
            // Scene-reconstruction anchors are live session output. Capture the
            // current ARFrame snapshot explicitly instead of assuming every
            // automatically generated mesh is present in ARWorldMap.anchors.
            let currentAnchors = sceneView.session.currentFrame?.anchors ?? []
            let meshAnchors = try await Task.detached(priority: .userInitiated) {
                try ARMeshSnapshotExtractor.records(from: currentAnchors)
            }.value
            let worldMap = try await currentWorldMap(from: sceneView.session)
            if !worldMap.anchors.contains(where: { $0.name == Self.mapOriginAnchorName }) {
                worldMap.anchors.append(
                    ARAnchor(
                        name: Self.mapOriginAnchorName,
                        transform: matrix_identity_float4x4
                    )
                )
            }

            let now = Date()
            let mapID = UUID()
            let spatialMap = try SpatialMapSnapshot(
                mapID: mapID,
                points: worldMap.rawFeaturePoints.points,
                identifiers: worldMap.rawFeaturePoints.identifiers,
                meshAnchors: meshAnchors
            )
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = now.formatted(
                .dateTime.year().month().day().hour().minute()
            )
            let metadata = MapMetadata(
                schemaVersion: MapMetadata.currentSchemaVersion,
                id: mapID,
                name: trimmedName.isEmpty ? "House \(fallbackName)" : trimmedName,
                createdAt: now,
                updatedAt: now,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                systemVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model,
                backend: "ARWorldMap",
                center: Vector3Record(
                    x: worldMap.center.x,
                    y: worldMap.center.y,
                    z: worldMap.center.z
                ),
                extent: Vector3Record(
                    x: worldMap.extent.x,
                    y: worldMap.extent.y,
                    z: worldMap.extent.z
                ),
                featurePointCount: spatialMap.landmarks.count,
                hasSceneDepth: hasDepth,
                hasSceneReconstruction: hasSceneReconstruction
            )
            let previewData = sceneView.snapshot().jpegData(compressionQuality: 0.78)
            let package = try await mapLibrary.save(
                worldMap: worldMap,
                spatialMap: spatialMap,
                metadata: metadata,
                previewData: previewData
            )
            mapRenderSnapshot = SpatialMapRenderSnapshot.make(
                landmarks: spatialMap.landmarks,
                maximumCount: Self.maximumMapRenderPointCount
            )
            meshRenderSnapshot = SpatialMeshRenderSnapshot.make(
                meshAnchors: spatialMap.meshAnchors,
                maximumTriangleCount: Self.maximumMapRenderTriangleCount
            )
            savedPackage = package
            statusMessage = "Map saved locally."

            do {
                let storage = try await mapLibrary.benchmarkStorageMetrics(for: package)
                let metrics = Self.makeMapBenchmarkMetrics(
                    package: package,
                    spatialMap: spatialMap,
                    storage: storage,
                    ioDuration: ProcessInfo.processInfo.systemUptime - persistenceStart
                )
                benchmarkMapMetrics = metrics
                benchmarkAccumulator.recordMap(metrics)
                let report = currentBenchmarkReport(completedAt: Date())
                try await mapLibrary.saveBenchmark(report, for: package)
                benchmarkReport = report
            } catch {
                statusMessage = "Map saved; device benchmark unavailable: \(error.localizedDescription)"
            }
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }

        isSaving = false
    }

    private func beginRelocalization(with worldMap: ARWorldMap) {
        guard let sceneView else { return }
        benchmarkAccumulator = SessionBenchmarkAccumulator(startedAt: Date())
        if let benchmarkMapMetrics { benchmarkAccumulator.recordMap(benchmarkMapMetrics) }
        benchmarkReport = nil
        originAnchorSeen = false
        relocalizationMachine.reset()
        pose = nil
        trail = []
        lastTrailPosition = nil
        lastPublishedPoseTimestamp = -.infinity
        lastFeatureOverlayTimestamp = -.infinity
        featurePointSnapshot = .empty
        relocalizationStartUptime = ProcessInfo.processInfo.systemUptime
        elapsedRelocalization = 0
        confidence = .low
        phase = .relocalizing
        statusMessage = "Move slowly and look at textured areas you scanned before."

        let configuration = makeConfiguration(initialWorldMap: worldMap)
        sceneView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )

        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        (RelocalizationStateMachine.timeout + Self.timeoutFallbackGrace)
                            * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            self?.applyRelocalizationTimeoutIfNeeded()
        }
    }

    private func makeConfiguration(initialWorldMap: ARWorldMap?) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        configuration.initialWorldMap = initialWorldMap

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            hasSceneReconstruction = true
            meshDescription = "Classified LiDAR mesh"
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            hasSceneReconstruction = true
            meshDescription = "LiDAR mesh"
        } else {
            hasSceneReconstruction = false
            meshDescription = "Scene mesh unavailable"
        }

        var semantics: ARConfiguration.FrameSemantics = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            semantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        }
        configuration.frameSemantics = semantics
        hasDepth = semantics.contains(.sceneDepth)
        if !hasDepth {
            depthDescription = "Scene depth unavailable"
        }

        return configuration
    }

    private func currentWorldMap(from session: ARSession) async throws -> ARWorldMap {
        try await withCheckedThrowingContinuation { continuation in
            session.getCurrentWorldMap { worldMap, error in
                if let worldMap {
                    continuation.resume(returning: worldMap)
                } else {
                    continuation.resume(
                        throwing: error ?? ARSessionControllerError.worldMapUnavailable
                    )
                }
            }
        }
    }

    private func consume(frame: ARFrame) {
        let imageResolution = frame.camera.imageResolution
        benchmarkAccumulator.recordFrame(
            timestamp: frame.timestamp,
            cameraWidth: Int(imageResolution.width),
            cameraHeight: Int(imageResolution.height),
            trackingCategory: Self.trackingBenchmarkCategory(frame.camera.trackingState)
        )
        if let captureSnapshot = captureDiagnostics.record(
            timestamp: frame.timestamp,
            imageWidth: Int(imageResolution.width),
            imageHeight: Int(imageResolution.height)
        ), captureDescription != captureSnapshot.description {
            captureDescription = captureSnapshot.description
        }
        updateTrackingDescription(frame.camera.trackingState)
        if frame.timestamp - lastDiagnosticPublicationTimestamp >= Self.diagnosticPublicationInterval {
            lastDiagnosticPublicationTimestamp = frame.timestamp
            updateMappingStatus(frame.worldMappingStatus)
            let currentFeaturePointCount = frame.rawFeaturePoints?.points.count ?? 0
            if featurePointCount != currentFeaturePointCount {
                featurePointCount = currentFeaturePointCount
            }
        }
        inspectDepthIfNeeded(frame.sceneDepth ?? frame.smoothedSceneDepth)

        var currentRelocalizationElapsed: TimeInterval = 0
        if let start = relocalizationStartUptime {
            currentRelocalizationElapsed = max(0, ProcessInfo.processInfo.systemUptime - start)
            if Int(currentRelocalizationElapsed) != Int(elapsedRelocalization) {
                elapsedRelocalization = currentRelocalizationElapsed
            }
        }

        let cameraPose = CameraPose(
            mapFromCamera: CoordinateFrames.mapFromCamera(
                mapFromWorld: matrix_identity_float4x4,
                worldFromCamera: frame.camera.transform
            ),
            eulerAngles: frame.camera.eulerAngles,
            timestamp: frame.timestamp
        )

        switch mode {
        case .mapping:
            publishPoseIfNeeded(cameraPose)
            if confidence != .unavailable { confidence = .unavailable }
            appendTrail(cameraPose.position)
            publishSpatialMapSnapshotIfNeeded(from: frame)

        case .relocalization:
            updateRelocalizationState(
                trackingState: frame.camera.trackingState,
                cameraPose: cameraPose,
                elapsedTime: currentRelocalizationElapsed
            )
        }

        publishFeatureOverlay(from: frame)
    }

    private func updateRelocalizationState(
        trackingState: ARCamera.TrackingState,
        cameraPose: CameraPose,
        elapsedTime: TimeInterval
    ) {
        let input: RelocalizationStateMachine.TrackingInput
        switch trackingState {
        case .normal:
            input = .normal
        case .limited(let reason):
            input = reason == .relocalizing ? .limitedRelocalizing : .limitedOther
        case .notAvailable:
            input = .unavailable
        }

        let output = relocalizationMachine.update(
            tracking: input,
            originIsPresent: originAnchorSeen,
            elapsedTime: elapsedTime
        )
        applyRelocalizationOutput(output)

        if output.shouldPublishPose {
            publishPoseIfNeeded(cameraPose, force: pose == nil)
            appendTrail(cameraPose.position)
        } else if pose != nil {
            pose = nil
        }
    }

    private func applyRelocalizationOutput(_ output: RelocalizationStateMachine.Output) {
        if phase != output.phase { phase = output.phase }
        if confidence != output.confidence { confidence = output.confidence }
        let message = output.reason.statusMessage
        if statusMessage != message { statusMessage = message }
        if output.phase == .tracking {
            relocalizationTimeoutTask?.cancel()
            relocalizationTimeoutTask = nil
        }
    }

    private func applyRelocalizationTimeoutIfNeeded() {
        guard case .relocalization = mode, phase != .tracking else { return }
        let output = relocalizationMachine.update(
            tracking: .unavailable,
            originIsPresent: originAnchorSeen,
            elapsedTime: RelocalizationStateMachine.timeout + Self.timeoutFallbackGrace
        )
        applyRelocalizationOutput(output)
        if !output.shouldPublishPose, pose != nil { pose = nil }
    }

    private func publishPoseIfNeeded(_ cameraPose: CameraPose, force: Bool = false) {
        guard force || cameraPose.timestamp - lastPublishedPoseTimestamp >= Self.displayPoseInterval else {
            return
        }
        lastPublishedPoseTimestamp = cameraPose.timestamp
        pose = cameraPose
    }

    private func publishFeatureOverlay(from frame: ARFrame) {
        guard frame.timestamp - lastFeatureOverlayTimestamp >= Self.featureOverlayPublicationInterval,
              let sceneView,
              sceneView.bounds.width > 0,
              sceneView.bounds.height > 0 else {
            return
        }
        lastFeatureOverlayTimestamp = frame.timestamp

        guard let pointCloud = frame.rawFeaturePoints else {
            publishEmptyFeatureSnapshot(timestamp: frame.timestamp)
            return
        }

        let points = pointCloud.points
        let identifiers = pointCloud.identifiers
        let sourceCount = min(points.count, identifiers.count)
        guard sourceCount > 0 else {
            publishEmptyFeatureSnapshot(timestamp: frame.timestamp)
            return
        }

        let viewportSize = sceneView.bounds.size
        let orientation = sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
        let cameraFromWorld = simd_inverse(frame.camera.transform)
        let overlayState: FeatureOverlayState
        switch mode {
        case .mapping:
            overlayState = .scanning
        case .relocalization:
            overlayState = phase == .tracking ? .localized : .seekingMap
        }

        var visibleCandidates: [VisibleFeatureCandidate] = []
        visibleCandidates.reserveCapacity(sourceCount)
        var rejectedBehindCameraCount = 0
        var rejectedInvalidProjectionCount = 0
        var rejectedOutsideViewportCount = 0
        for index in 0..<sourceCount {
            let worldPoint = points[index]
            let cameraPoint = simd_mul(
                cameraFromWorld,
                SIMD4(worldPoint.x, worldPoint.y, worldPoint.z, 1)
            )
            guard cameraPoint.z < -0.05 else {
                rejectedBehindCameraCount += 1
                continue
            }

            let projected = frame.camera.projectPoint(
                worldPoint,
                orientation: orientation,
                viewportSize: viewportSize
            )
            guard projected.x.isFinite, projected.y.isFinite else {
                rejectedInvalidProjectionCount += 1
                continue
            }
            guard projected.x >= 0,
                  projected.y >= 0,
                  projected.x <= viewportSize.width,
                  projected.y <= viewportSize.height else {
                rejectedOutsideViewportCount += 1
                continue
            }

            visibleCandidates.append(
                VisibleFeatureCandidate(
                    id: identifiers[index],
                    position: SIMD2(
                        Float(projected.x / viewportSize.width),
                        Float(projected.y / viewportSize.height)
                    )
                )
            )
        }

        let verifiedPriorityIdentifiers: Set<UInt64>
        if overlayState == .localized {
            verifiedPriorityIdentifiers = Set(
                visibleCandidates.lazy
                    .map(\.id)
                    .filter(savedFeatureIdentifiers.contains)
                    .prefix(Self.maximumPriorityFeaturePointCount)
            )
        } else {
            verifiedPriorityIdentifiers = []
        }
        let selectedCandidates = FeaturePointPresentation.selectVisibleCandidates(
            visibleCandidates,
            maximumCount: Self.maximumScreenFeaturePointCount,
            priorityIdentifiers: verifiedPriorityIdentifiers
        )
        let projectedPoints = selectedCandidates.map { candidate in
            ScreenFeaturePoint(
                id: candidate.id,
                position: candidate.position,
                role: FeaturePointPresentation.role(
                    for: candidate.id,
                    savedIdentifiers: savedFeatureIdentifiers,
                    state: overlayState
                )
            )
        }
        let identityMatchCount = overlayState == .localized
            ? visibleCandidates.lazy.filter { self.savedFeatureIdentifiers.contains($0.id) }.count
            : 0

        let snapshot = FeaturePointSnapshot(
            points: projectedPoints,
            observedCount: sourceCount,
            visibleCount: visibleCandidates.count,
            rejectedBehindCameraCount: rejectedBehindCameraCount,
            rejectedInvalidProjectionCount: rejectedInvalidProjectionCount,
            rejectedOutsideViewportCount: rejectedOutsideViewportCount,
            mapIdentityMatchCount: identityMatchCount,
            timestamp: frame.timestamp
        )
        featurePointSnapshot = snapshot
        benchmarkAccumulator.recordFeatureSnapshot(snapshot)
    }

    private func publishEmptyFeatureSnapshot(timestamp: TimeInterval) {
        let snapshot = FeaturePointSnapshot(
            points: [],
            observedCount: 0,
            visibleCount: 0,
            rejectedBehindCameraCount: 0,
            rejectedInvalidProjectionCount: 0,
            rejectedOutsideViewportCount: 0,
            mapIdentityMatchCount: 0,
            timestamp: timestamp
        )
        if featurePointSnapshot != snapshot { featurePointSnapshot = snapshot }
        benchmarkAccumulator.recordFeatureSnapshot(snapshot)
    }

    private func updateTrackingDescription(_ state: ARCamera.TrackingState) {
        let description: String
        switch state {
        case .normal:
            description = "Normal"
        case .notAvailable:
            description = "Not available"
        case .limited(let reason):
            switch reason {
            case .initializing: description = "Limited — initializing"
            case .excessiveMotion: description = "Limited — move slower"
            case .insufficientFeatures: description = "Limited — point at textured surfaces"
            case .relocalizing: description = "Limited — matching saved map"
            @unknown default: description = "Limited"
            }
        }
        if trackingDescription != description { trackingDescription = description }
    }

    private func updateMappingStatus(_ status: ARFrame.WorldMappingStatus) {
        let description: String
        let progress: Double
        switch status {
        case .notAvailable:
            description = "Not available"
            progress = 0
        case .limited:
            description = "Limited"
            progress = 0.25
        case .extending:
            description = "Extending"
            progress = 0.65
        case .mapped:
            description = "Mapped"
            progress = 1
        @unknown default:
            description = "Unknown"
            progress = 0
        }
        if mappingDescription != description { mappingDescription = description }
        if mappingProgress != progress { mappingProgress = progress }

        if case .mapping = mode {
            let shouldAllowSave = (status == .extending || status == .mapped)
                && trackingDescription == "Normal"
            if canSave != shouldAllowSave { canSave = shouldAllowSave }
        }
    }

    private func appendTrail(_ position: SIMD3<Float>) {
        let point = SIMD2(position.x, position.z)
        if let lastTrailPosition, simd_distance(lastTrailPosition, point) < 0.08 {
            return
        }
        lastTrailPosition = point
        trail.append(point)
        if trail.count > 650 {
            trail.removeFirst(50)
        }
    }

    private func publishSpatialMapSnapshotIfNeeded(from frame: ARFrame) {
        guard frame.timestamp - lastCoveragePublicationTimestamp >= Self.coveragePublicationInterval,
              let pointCloud = frame.rawFeaturePoints else { return }
        lastCoveragePublicationTimestamp = frame.timestamp

        mappingLandmarks.integrate(
            points: pointCloud.points,
            identifiers: pointCloud.identifiers
        )
        let snapshot = mappingLandmarks.renderSnapshot(
            maximumCount: Self.maximumMapRenderPointCount
        )
        if snapshot != mapRenderSnapshot {
            mapRenderSnapshot = snapshot
        }
    }

    private func inspectDepthIfNeeded(_ depthData: ARDepthData?) {
        guard Date().timeIntervalSince(lastDepthInspection) >= 1 else { return }
        lastDepthInspection = Date()
        guard let depthData else {
            depthDescription = hasDepth ? "Waiting for depth samples" : "Scene depth unavailable"
            return
        }

        let depthMap = depthData.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        var detail = "\(width)×\(height) depth"
        let confidenceFraction = Self.highConfidenceFraction(in: depthData)
        if let confidenceFraction {
            detail += " • \(Int(confidenceFraction * 100))% high confidence"
        }
        if depthDescription != detail { depthDescription = detail }
        benchmarkAccumulator.recordDepth(
            DepthBenchmarkMetrics(
                width: width,
                height: height,
                highConfidenceFraction: confidenceFraction
            )
        )
    }

    func currentBenchmarkReport(completedAt: Date = Date()) -> SessionBenchmarkReport {
        benchmarkAccumulator.makeReport(
            mode: mode.benchmarkMode,
            completedAt: completedAt,
            deviceModel: Self.hardwareModelIdentifier,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )
    }

    private static func makeMapBenchmarkMetrics(
        package: MapPackage,
        spatialMap: SpatialMapSnapshot,
        storage: (spatialMapByteCount: Int?, packageByteCount: Int64),
        ioDuration: TimeInterval
    ) -> MapBenchmarkMetrics {
        MapBenchmarkMetrics(
            mapID: package.id,
            mapName: package.metadata.name,
            landmarkCount: spatialMap.landmarks.count,
            meshAnchorCount: spatialMap.meshAnchors.count,
            meshVertexCount: spatialMap.meshAnchors.reduce(0) { $0 + $1.vertices.count },
            meshTriangleCount: spatialMap.meshAnchors.reduce(0) { $0 + $1.faces.count },
            spatialMapByteCount: storage.spatialMapByteCount,
            packageByteCount: storage.packageByteCount,
            ioDuration: max(0, ioDuration)
        )
    }

    private static func trackingBenchmarkCategory(
        _ state: ARCamera.TrackingState
    ) -> TrackingBenchmarkCategory {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .unavailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .limitedInitializing
            case .excessiveMotion: return .limitedExcessiveMotion
            case .insufficientFeatures: return .limitedInsufficientFeatures
            case .relocalizing: return .limitedRelocalizing
            @unknown default: return .limitedOther
            }
        }
    }

    private static func highConfidenceFraction(in depthData: ARDepthData) -> Double? {
        guard let confidenceMap = depthData.confidenceMap,
              CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        var high = 0
        var sampled = 0
        for y in stride(from: 0, to: height, by: 4) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: 4) {
                sampled += 1
                if row[x] == UInt8(ARConfidenceLevel.high.rawValue) { high += 1 }
            }
        }
        return sampled > 0 ? Double(high) / Double(sampled) : nil
    }

    private static var hardwareModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

}

extension ARSessionController: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        consume(frame: frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        if anchors.contains(where: { $0.name == Self.mapOriginAnchorName }) {
            originAnchorSeen = true
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        phase = .interrupted
        confidence = .unavailable
        pose = nil
        statusMessage = "The AR session was interrupted. Keep the phone near mapped content while it recovers."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        statusMessage = "Attempting to recover tracking…"
        if case .relocalization = mode {
            phase = .relocalizing
            confidence = .low
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        phase = .failed
        confidence = .unavailable
        pose = nil
        statusMessage = error.localizedDescription
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }
}

extension ARSessionController: @preconcurrency ARSCNViewDelegate {
    func renderer(
        _ renderer: SCNSceneRenderer,
        didAdd node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        lastMeshUpdateByAnchor[meshAnchor.identifier] = ProcessInfo.processInfo.systemUptime
        node.geometry = makeMeshGeometry(from: meshAnchor.geometry)
    }

    func renderer(
        _ renderer: SCNSceneRenderer,
        didUpdate node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastUpdate = lastMeshUpdateByAnchor[meshAnchor.identifier],
           now - lastUpdate < Self.meshUpdateInterval {
            return
        }
        lastMeshUpdateByAnchor[meshAnchor.identifier] = now
        node.geometry = makeMeshGeometry(from: meshAnchor.geometry)
    }

    func renderer(
        _ renderer: SCNSceneRenderer,
        didRemove node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        lastMeshUpdateByAnchor.removeValue(forKey: meshAnchor.identifier)
    }

    private func makeMeshGeometry(from mesh: ARMeshGeometry) -> SCNGeometry {
        let vertices = SCNGeometrySource(
            buffer: mesh.vertices.buffer,
            vertexFormat: mesh.vertices.format,
            semantic: .vertex,
            vertexCount: mesh.vertices.count,
            dataOffset: mesh.vertices.offset,
            dataStride: mesh.vertices.stride
        )
        let normals = SCNGeometrySource(
            buffer: mesh.normals.buffer,
            vertexFormat: mesh.normals.format,
            semantic: .normal,
            vertexCount: mesh.normals.count,
            dataOffset: mesh.normals.offset,
            dataStride: mesh.normals.stride
        )
        let faces = SCNGeometryElement(
            buffer: mesh.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: mesh.faces.count,
            bytesPerIndex: mesh.faces.bytesPerIndex
        )
        let geometry = SCNGeometry(sources: [vertices, normals], elements: [faces])
        geometry.materials = [meshVisualizationMaterial]
        return geometry
    }
}

enum ARSessionControllerError: LocalizedError {
    case worldMapUnavailable

    var errorDescription: String? {
        switch self {
        case .worldMapUnavailable:
            return "ARKit did not produce a world map. Continue scanning and try again."
        }
    }
}

/// Losslessly copies ARKit's transient Metal-backed mesh buffers into the
/// app-owned persistent map schema. Coordinates remain anchor-local and the
/// exact `T_map_anchor` transform is stored alongside them.
enum ARMeshSnapshotExtractor {
    static func records(from anchors: [ARAnchor]) throws -> [SpatialMeshAnchorRecord] {
        try anchors.compactMap { anchor in
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            return try record(from: meshAnchor)
        }
    }

    private static func record(from anchor: ARMeshAnchor) throws -> SpatialMeshAnchorRecord {
        let geometry = anchor.geometry
        let vertices = try vectors(
            from: geometry.vertices,
            anchorID: anchor.identifier,
            semantic: "vertices"
        )
        let normals = try vectors(
            from: geometry.normals,
            anchorID: anchor.identifier,
            semantic: "normals"
        )
        let classifications = try classifications(
            from: geometry.classification,
            expectedCount: geometry.faces.count,
            anchorID: anchor.identifier
        )
        let indices = try triangleIndices(
            from: geometry.faces,
            anchorID: anchor.identifier
        )
        let faces = indices.enumerated().map { faceIndex, triangle in
            SpatialMeshFaceRecord(
                firstVertexIndex: triangle.0,
                secondVertexIndex: triangle.1,
                thirdVertexIndex: triangle.2,
                classificationRawValue: classifications?[faceIndex]
            )
        }
        return try SpatialMeshAnchorRecord(
            id: anchor.identifier,
            mapFromAnchor: SpatialTransformRecord(anchor.transform),
            vertices: vertices,
            normals: normals,
            faces: faces
        )
    }

    private static func vectors(
        from source: ARGeometrySource,
        anchorID: UUID,
        semantic: String
    ) throws -> [Vector3Record] {
        guard source.format == .float3, source.componentsPerVector == 3 else {
            throw ARMeshSnapshotExtractionError.unsupportedVectorFormat(
                anchorID: anchorID,
                semantic: semantic,
                format: source.format.rawValue,
                components: source.componentsPerVector
            )
        }
        let componentBytes = MemoryLayout<Float>.size * 3
        guard source.offset >= 0,
              source.stride >= componentBytes,
              source.count >= 0,
              requiredLength(offset: source.offset, stride: source.stride, count: source.count, itemBytes: componentBytes) <= source.buffer.length else {
            throw ARMeshSnapshotExtractionError.invalidBufferLayout(anchorID: anchorID, semantic: semantic)
        }
        let buffer = UnsafeRawPointer(source.buffer.contents())
        return (0..<source.count).map { index in
            let offset = source.offset + index * source.stride
            return Vector3Record(
                x: buffer.loadUnaligned(fromByteOffset: offset, as: Float.self),
                y: buffer.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                z: buffer.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
            )
        }
    }

    private static func triangleIndices(
        from element: ARGeometryElement,
        anchorID: UUID
    ) throws -> [(UInt32, UInt32, UInt32)] {
        guard element.primitiveType == .triangle, element.indexCountPerPrimitive == 3 else {
            throw ARMeshSnapshotExtractionError.unsupportedPrimitive(anchorID: anchorID)
        }
        guard element.bytesPerIndex == 2 || element.bytesPerIndex == 4 else {
            throw ARMeshSnapshotExtractionError.unsupportedIndexWidth(
                anchorID: anchorID,
                bytesPerIndex: element.bytesPerIndex
            )
        }
        let itemBytes = element.bytesPerIndex * 3
        guard element.count >= 0,
              requiredLength(offset: 0, stride: itemBytes, count: element.count, itemBytes: itemBytes) <= element.buffer.length else {
            throw ARMeshSnapshotExtractionError.invalidBufferLayout(anchorID: anchorID, semantic: "faces")
        }
        let buffer = UnsafeRawPointer(element.buffer.contents())
        return (0..<element.count).map { faceIndex in
            let base = faceIndex * itemBytes
            if element.bytesPerIndex == 2 {
                return (
                    UInt32(buffer.loadUnaligned(fromByteOffset: base, as: UInt16.self)),
                    UInt32(buffer.loadUnaligned(fromByteOffset: base + 2, as: UInt16.self)),
                    UInt32(buffer.loadUnaligned(fromByteOffset: base + 4, as: UInt16.self))
                )
            }
            return (
                buffer.loadUnaligned(fromByteOffset: base, as: UInt32.self),
                buffer.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self),
                buffer.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)
            )
        }
    }

    private static func classifications(
        from source: ARGeometrySource?,
        expectedCount: Int,
        anchorID: UUID
    ) throws -> [Int]? {
        guard let source else { return nil }
        guard source.format == .uchar, source.componentsPerVector == 1 else {
            throw ARMeshSnapshotExtractionError.unsupportedClassificationFormat(
                anchorID: anchorID,
                format: source.format.rawValue,
                components: source.componentsPerVector
            )
        }
        guard source.count == expectedCount,
              source.offset >= 0,
              source.stride >= 1,
              requiredLength(offset: source.offset, stride: source.stride, count: source.count, itemBytes: 1) <= source.buffer.length else {
            throw ARMeshSnapshotExtractionError.invalidBufferLayout(anchorID: anchorID, semantic: "classification")
        }
        let buffer = UnsafeRawPointer(source.buffer.contents())
        return (0..<source.count).map { index in
            Int(buffer.loadUnaligned(fromByteOffset: source.offset + index * source.stride, as: UInt8.self))
        }
    }

    private static func requiredLength(
        offset: Int,
        stride: Int,
        count: Int,
        itemBytes: Int
    ) -> Int {
        guard count > 0 else { return max(offset, 0) }
        let (strideBytes, strideOverflow) = (count - 1).multipliedReportingOverflow(by: stride)
        let (prefixBytes, prefixOverflow) = offset.addingReportingOverflow(strideBytes)
        let (totalBytes, totalOverflow) = prefixBytes.addingReportingOverflow(itemBytes)
        return strideOverflow || prefixOverflow || totalOverflow ? .max : totalBytes
    }
}

enum ARMeshSnapshotExtractionError: LocalizedError {
    case unsupportedVectorFormat(anchorID: UUID, semantic: String, format: UInt, components: Int)
    case unsupportedPrimitive(anchorID: UUID)
    case unsupportedIndexWidth(anchorID: UUID, bytesPerIndex: Int)
    case unsupportedClassificationFormat(anchorID: UUID, format: UInt, components: Int)
    case invalidBufferLayout(anchorID: UUID, semantic: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVectorFormat(let id, let semantic, let format, let components):
            return "Mesh anchor \(id) has unsupported \(semantic) format \(format) with \(components) components."
        case .unsupportedPrimitive(let id):
            return "Mesh anchor \(id) does not contain triangle primitives."
        case .unsupportedIndexWidth(let id, let bytes):
            return "Mesh anchor \(id) uses an unsupported \(bytes)-byte triangle index."
        case .unsupportedClassificationFormat(let id, let format, let components):
            return "Mesh anchor \(id) has unsupported classification format \(format) with \(components) components."
        case .invalidBufferLayout(let id, let semantic):
            return "Mesh anchor \(id) has an invalid \(semantic) buffer layout."
        }
    }
}
