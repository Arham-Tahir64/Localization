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
    @Published private(set) var depthDescription = "Waiting for LiDAR"
    @Published private(set) var meshDescription = "Checking support"
    @Published private(set) var pose: CameraPose?
    @Published private(set) var mapPoints: [SIMD2<Float>] = []
    @Published private(set) var trail: [SIMD2<Float>] = []
    @Published private(set) var elapsedRelocalization: TimeInterval = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var savedPackage: MapPackage?
    @Published private(set) var canSave = false

    let mode: ExperienceMode

    private let mapLibrary: MapLibrary
    private weak var sceneView: ARSCNView?
    private var hasStarted = false
    private var hasDepth = false
    private var hasSceneReconstruction = false
    private var originAnchorSeen = false
    private var relocalizationMachine = RelocalizationStateMachine()
    private var frameCount = 0
    private var relocalizationStart: Date?
    private var lastDepthInspection = Date.distantPast
    private var lastTrailPosition: SIMD2<Float>?
    private var coverageGrid: Set<GridKey> = []
    private var loadedWorldMap: ARWorldMap?

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
        view.antialiasingMode = .multisampling4X
        view.scene = SCNScene()
        view.debugOptions = [.showFeaturePoints, .showWorldOrigin]
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
                    let worldMap = try await mapLibrary.loadWorldMap(from: package)
                    guard self.hasStarted else { return }
                    self.loadedWorldMap = worldMap
                    self.mapPoints = Self.overviewPoints(
                        from: worldMap.rawFeaturePoints.points,
                        maximumCount: 2_000
                    )
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
        sceneView?.session.pause()
    }

    func saveMap(named rawName: String) async {
        guard case .mapping = mode,
              canSave,
              !isSaving,
              let sceneView else { return }

        isSaving = true
        statusMessage = "Capturing persistent world map…"

        do {
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
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = now.formatted(
                .dateTime.year().month().day().hour().minute()
            )
            let metadata = MapMetadata(
                schemaVersion: MapMetadata.currentSchemaVersion,
                id: UUID(),
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
                featurePointCount: worldMap.rawFeaturePoints.points.count,
                hasSceneDepth: hasDepth,
                hasSceneReconstruction: hasSceneReconstruction
            )
            let previewData = sceneView.snapshot().jpegData(compressionQuality: 0.78)
            let package = try await mapLibrary.save(
                worldMap: worldMap,
                metadata: metadata,
                previewData: previewData
            )
            savedPackage = package
            statusMessage = "Map saved locally."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }

        isSaving = false
    }

    private func beginRelocalization(with worldMap: ARWorldMap) {
        guard let sceneView else { return }
        originAnchorSeen = false
        relocalizationMachine.reset()
        pose = nil
        trail = []
        lastTrailPosition = nil
        relocalizationStart = Date()
        elapsedRelocalization = 0
        confidence = .low
        phase = .relocalizing
        statusMessage = "Move slowly and look at textured areas you scanned before."

        let configuration = makeConfiguration(initialWorldMap: worldMap)
        sceneView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
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
        frameCount += 1
        updateTrackingDescription(frame.camera.trackingState)
        updateMappingStatus(frame.worldMappingStatus)
        featurePointCount = frame.rawFeaturePoints?.points.count ?? 0
        inspectDepthIfNeeded(frame.sceneDepth ?? frame.smoothedSceneDepth)

        if let start = relocalizationStart, phase != .tracking {
            elapsedRelocalization = Date().timeIntervalSince(start)
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
            pose = cameraPose
            confidence = .unavailable
            appendTrail(cameraPose.position)
            accumulateCoverage(from: frame)

        case .relocalization:
            updateRelocalizationState(
                trackingState: frame.camera.trackingState,
                cameraPose: cameraPose
            )
        }
    }

    private func updateRelocalizationState(
        trackingState: ARCamera.TrackingState,
        cameraPose: CameraPose
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
            elapsedTime: elapsedRelocalization
        )
        phase = output.phase
        confidence = output.confidence
        statusMessage = output.reason.statusMessage

        if output.shouldPublishPose {
            pose = cameraPose
            appendTrail(cameraPose.position)
        } else {
            pose = nil
        }
    }

    private func updateTrackingDescription(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            trackingDescription = "Normal"
        case .notAvailable:
            trackingDescription = "Not available"
        case .limited(let reason):
            switch reason {
            case .initializing: trackingDescription = "Limited — initializing"
            case .excessiveMotion: trackingDescription = "Limited — move slower"
            case .insufficientFeatures: trackingDescription = "Limited — point at textured surfaces"
            case .relocalizing: trackingDescription = "Limited — matching saved map"
            @unknown default: trackingDescription = "Limited"
            }
        }
    }

    private func updateMappingStatus(_ status: ARFrame.WorldMappingStatus) {
        switch status {
        case .notAvailable:
            mappingDescription = "Not available"
            mappingProgress = 0
        case .limited:
            mappingDescription = "Limited"
            mappingProgress = 0.25
        case .extending:
            mappingDescription = "Extending"
            mappingProgress = 0.65
        case .mapped:
            mappingDescription = "Mapped"
            mappingProgress = 1
        @unknown default:
            mappingDescription = "Unknown"
            mappingProgress = 0
        }

        if case .mapping = mode {
            canSave = (status == .extending || status == .mapped) && trackingDescription == "Normal"
        }
    }

    private func appendTrail(_ position: SIMD3<Float>) {
        let point = SIMD2(position.x, position.z)
        if let lastTrailPosition, simd_distance(lastTrailPosition, point) < 0.08 {
            return
        }
        lastTrailPosition = point
        trail.append(point)
        if trail.count > 1_000 {
            trail.removeFirst(trail.count - 1_000)
        }
    }

    private func accumulateCoverage(from frame: ARFrame) {
        guard frameCount.isMultiple(of: 8),
              coverageGrid.count < 2_000,
              let points = frame.rawFeaturePoints?.points else { return }

        for point in points.stride(from: 0, by: max(1, points.count / 120)) {
            let key = GridKey(
                x: Int((point.x / 0.20).rounded()),
                z: Int((point.z / 0.20).rounded())
            )
            coverageGrid.insert(key)
            if coverageGrid.count >= 2_000 { break }
        }
        mapPoints = coverageGrid.map { key in
            SIMD2(Float(key.x) * 0.20, Float(key.z) * 0.20)
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

        if let confidenceMap = depthData.confidenceMap,
           CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8 {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(confidenceMap) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
                let confidenceWidth = CVPixelBufferGetWidth(confidenceMap)
                let confidenceHeight = CVPixelBufferGetHeight(confidenceMap)
                var high = 0
                var sampled = 0
                for y in stride(from: 0, to: confidenceHeight, by: 4) {
                    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for x in stride(from: 0, to: confidenceWidth, by: 4) {
                        sampled += 1
                        if row[x] == UInt8(ARConfidenceLevel.high.rawValue) { high += 1 }
                    }
                }
                if sampled > 0 {
                    detail += " • \(Int((Double(high) / Double(sampled)) * 100))% high confidence"
                }
            }
        }
        depthDescription = detail
    }

    private static func overviewPoints(
        from points: [SIMD3<Float>],
        maximumCount: Int
    ) -> [SIMD2<Float>] {
        guard points.count > maximumCount else {
            return points.map { SIMD2($0.x, $0.z) }
        }
        let strideSize = max(1, points.count / maximumCount)
        return points.stride(from: 0, by: strideSize).prefix(maximumCount).map {
            SIMD2($0.x, $0.z)
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

extension ARSessionController: ARSCNViewDelegate {
    func renderer(
        _ renderer: SCNSceneRenderer,
        didAdd node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.geometry = makeMeshGeometry(from: meshAnchor.geometry)
    }

    func renderer(
        _ renderer: SCNSceneRenderer,
        didUpdate node: SCNNode,
        for anchor: ARAnchor
    ) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.geometry = makeMeshGeometry(from: meshAnchor.geometry)
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
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.32)
        material.isDoubleSided = true
        geometry.materials = [material]
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

private extension Array {
    func stride(from start: Int, by step: Int) -> [Element] {
        guard !isEmpty, start < count, step > 0 else { return [] }
        return Swift.stride(from: start, to: count, by: step).map { self[$0] }
    }
}
