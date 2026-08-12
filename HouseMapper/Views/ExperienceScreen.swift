import SwiftUI
import UIKit

struct ExperienceScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var validationStore: ValidationStore
    @StateObject private var controller: ARSessionController
    @State private var mapName = "My House"
    @State private var showingSaveDialog = false
    @State private var showingSavedAlert = false
    @State private var validationStartedAt: Date?
    @State private var validationStartTracking = "Waiting for camera"
    @State private var validationStartConfidence = ConfidenceBand.unavailable.rawValue
    @State private var validationAttemptRecorded = false

    private let mode: ExperienceMode

    init(mode: ExperienceMode, mapLibrary: MapLibrary) {
        self.mode = mode
        _controller = StateObject(
            wrappedValue: ARSessionController(mode: mode, mapLibrary: mapLibrary)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                spatialConsole(size: proxy.size)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)

        }
        .preferredColorScheme(.dark)
        .onAppear { beginValidationAttemptIfNeeded() }
        .onDisappear {
            recordValidationIfNeeded(outcome: .cancelled, notes: "Relocalization view closed before completion.")
            controller.stop()
        }
        .onChange(of: controller.phase) { _, phase in
            guard case .relocalization = mode else { return }
            switch phase {
            case .tracking:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                recordValidationIfNeeded(outcome: .success)
            case .failed:
                let outcome: ValidationOutcome = controller.elapsedRelocalization >= RelocalizationStateMachine.timeout
                    ? .timeout
                    : .sessionFailure
                recordValidationIfNeeded(outcome: outcome, notes: controller.statusMessage)
            default:
                break
            }
        }
        .onChange(of: controller.savedPackage) { _, package in
            showingSavedAlert = package != nil
        }
        .sheet(isPresented: $showingSaveDialog) {
            SaveMapSheet(
                name: $mapName,
                isSaving: controller.isSaving,
                onCancel: { showingSaveDialog = false },
                onSave: {
                    Task {
                        await controller.saveMap(named: mapName)
                        if controller.savedPackage != nil {
                            showingSaveDialog = false
                        }
                    }
                }
            )
            .presentationDetents([.height(250)])
        }
        .alert("Map saved", isPresented: $showingSavedAlert) {
            Button("Continue Mapping", role: .cancel) {}
            Button("Close") { dismiss() }
        } message: {
            Text("The map is stored locally and is ready for a relocalization test after restarting the app.")
        }
    }

    private func spatialConsole(size: CGSize) -> some View {
        VStack(spacing: 4) {
            cameraHeader

            if case .mapping = mode {
                ProgressView(value: controller.mappingProgress)
                    .tint(experienceColor)
                    .scaleEffect(y: 0.42)
                    .accessibilityLabel("Mapping progress")
            }

            HStack(spacing: 4) {
                SpatialPointCloudView(
                    map: controller.mapRenderSnapshot,
                    trail: controller.trail,
                    pose: controller.pose,
                    localizationSupportPoints: controller.phase == .tracking
                        ? controller.localizationSupportPoints
                        : [],
                    accentColor: experienceColor
                )
                .overlay(alignment: .topLeading) {
                    consolePanelLabel(
                        mapPanelTitle,
                        detail: mapPanelCount
                    )
                }
                .frame(width: max(190, size.width * 0.64))

                VStack(spacing: 4) {
                    cameraPanel
                        .frame(maxHeight: .infinity)

                    MapOverviewView(
                        map: controller.mapRenderSnapshot,
                        mesh: controller.meshRenderSnapshot,
                        trail: controller.trail,
                        pose: controller.pose,
                        accentColor: experienceColor
                    )
                    .overlay(alignment: .topLeading) {
                        consolePanelLabel("ROUTE", detail: trajectoryDetail)
                    }
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 4) {
                        AttitudeInstrumentView(
                            pitch: controller.pose?.eulerAngles.x,
                            roll: controller.pose?.eulerAngles.z,
                            accentColor: experienceColor
                        )
                        MapHeadingInstrumentView(
                            yaw: controller.pose?.eulerAngles.y,
                            accentColor: experienceColor
                        )
                    }
                    .frame(maxHeight: .infinity)

                    compactControl
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var cameraPanel: some View {
        ZStack {
            ARSceneView(controller: controller)
            SpatialFeatureOverlay(snapshot: controller.featurePointSnapshot)
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            consolePanelLabel("LIVE VIDEO", detail: featureDetail)
        }
        .overlay {
            Rectangle().stroke(.white.opacity(0.14), lineWidth: 0.75)
        }
        .accessibilityLabel("Live camera with tracked feature points")
    }

    private func consolePanelLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.55)
            Text(detail)
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(6)
        .shadow(color: .black, radius: 2)
        .allowsHitTesting(false)
    }

    private var featureDetail: String {
        let snapshot = controller.featurePointSnapshot
        if snapshot.serverVerifiedInlierCount > 0 {
            return "\(snapshot.serverVerifiedInlierCount) PNP INLIERS"
        }
        if snapshot.mapIdentityMatchCount > 0 {
            return "\(snapshot.mapIdentityMatchCount) RESTORED IDS"
        }
        return "\(snapshot.displayedCount)/\(snapshot.observedCount) FEATURES"
    }

    private var trajectoryDetail: String {
        guard let pose = controller.pose else { return "POSE WITHHELD" }
        return String(format: "X %+.1f  Z %+.1f M", pose.position.x, pose.position.z)
    }

    private var cameraHeader: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .frame(width: 36, height: 42)
                    .background(.black.opacity(0.92))
                    .overlay {
                        Rectangle().stroke(.white.opacity(0.14), lineWidth: 0.75)
                    }
            }
            .accessibilityLabel("Close spatial session")

            SpatialStatusCapsule(
                title: statusTitle,
                detail: statusDetail,
                featureCount: controller.featurePointSnapshot.displayedCount,
                visibleFeatureCount: controller.featurePointSnapshot.visibleCount,
                sourceFeatureCount: controller.featurePointSnapshot.observedCount,
                matchCount: controller.featurePointSnapshot.mapIdentityMatchCount,
                serverInlierCount: controller.featurePointSnapshot.serverVerifiedInlierCount,
                color: experienceColor
            )
        }
    }

    private var statusDetail: String {
        switch mode {
        case .mapping:
            return "\(controller.trackingDescription) • \(controller.captureDescription)"
        case .relocalization:
            return "\(controller.trackingDescription) • \(controller.serverLocalizationDescription)"
        }
    }

    private var statusTitle: String {
        switch mode {
        case .mapping:
            return controller.mappingDescription == "Mapped" ? "Map ready" : "Scanning"
        case .relocalization:
            switch controller.phase {
            case .loading: return "Loading map"
            case .relocalizing: return "Finding map"
            case .tracking: return "Localized"
            case .limited: return "Tracking limited"
            case .interrupted: return "Interrupted"
            case .failed: return "No map match"
            case .unsupported: return "Unsupported"
            case .mapping: return "Scanning"
            }
        }
    }

    private var experienceColor: Color {
        switch controller.phase {
        case .tracking:
            return .green
        case .failed, .unsupported:
            return .red
        case .limited, .interrupted, .loading, .relocalizing:
            return .orange
        case .mapping:
            return .cyan
        }
    }

    private var mapPanelTitle: String {
        switch mode {
        case .mapping:
            return "LIVE SPATIAL MAP"
        case .relocalization:
            return "SAVED SPATIAL MAP"
        }
    }

    private var mapPanelCount: String {
        let sourceCount = controller.mapRenderSnapshot.sourceCount
        let sourceTriangles = controller.meshRenderSnapshot.sourceTriangleCount
        guard sourceCount > 0 || sourceTriangles > 0 else { return "WAITING FOR GEOMETRY" }
        let renderedCount = controller.mapRenderSnapshot.points.count
        let landmarkText = renderedCount == sourceCount
            ? "\(sourceCount.formatted()) LANDMARKS"
            : "\(renderedCount.formatted()) OF \(sourceCount.formatted()) SHOWN"
        return sourceTriangles > 0
            ? "\(landmarkText) • \(sourceTriangles.formatted()) TRI • \(controller.mappingKeyframeCount) KF"
            : "\(landmarkText) • \(controller.mappingKeyframeCount) KF"
    }

    @ViewBuilder
    private var compactControl: some View {
        switch mode {
        case .mapping:
            Button {
                showingSaveDialog = true
            } label: {
                Label(
                    controller.isSaving ? "SAVING" : "SAVE MAP",
                    systemImage: "square.and.arrow.down"
                )
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(!controller.canSave || controller.isSaving)

        case .relocalization:
            if controller.phase == .failed || controller.phase == .limited {
                Button {
                    beginValidationAttemptIfNeeded(forceNewAttempt: true)
                    controller.retryRelocalization()
                } label: {
                    Label("RETRY", systemImage: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else if controller.phase == .tracking {
                Label("POSE LOCKED", systemImage: "location.fill")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(.green.opacity(0.10))
                    .overlay {
                        Rectangle().stroke(.green.opacity(0.42), lineWidth: 0.75)
                    }
            } else {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(experienceColor)
                    Text("SEARCH \(Int(controller.elapsedRelocalization))S")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(.white.opacity(0.04))
                .overlay {
                    Rectangle().stroke(.white.opacity(0.14), lineWidth: 0.75)
                }
            }
        }
    }

    private func beginValidationAttemptIfNeeded(forceNewAttempt: Bool = false) {
        guard case .relocalization = mode else { return }
        if forceNewAttempt || validationStartedAt == nil {
            validationStartedAt = Date()
            validationStartTracking = controller.trackingDescription
            validationStartConfidence = controller.confidence.rawValue
            validationAttemptRecorded = false
        }
    }

    private func recordValidationIfNeeded(
        outcome: ValidationOutcome,
        notes: String? = nil
    ) {
        guard !validationAttemptRecorded,
              let startedAt = validationStartedAt,
              case .relocalization(let package) = mode else { return }

        let finalPosition = controller.pose.map {
            ValidationPosition(x: $0.position.x, y: $0.position.y, z: $0.position.z)
        }
        let finalOrientation = controller.pose.map {
            ValidationOrientation(
                pitch: $0.eulerAngles.x,
                yaw: $0.eulerAngles.y,
                roll: $0.eulerAngles.z
            )
        }
        validationStore.append(
            ValidationRecord(
                mapID: package.id,
                mapName: package.metadata.name,
                startedAt: startedAt,
                completedAt: Date(),
                outcome: outcome,
                startTrackingLabel: validationStartTracking,
                endTrackingLabel: controller.trackingDescription,
                startConfidenceLabel: validationStartConfidence,
                endConfidenceLabel: controller.confidence.rawValue,
                finalPosition: finalPosition,
                finalOrientation: finalOrientation,
                notes: notes,
                benchmark: controller.currentBenchmarkReport()
            )
        )
        validationAttemptRecorded = true
    }
}
private struct SaveMapSheet: View {
    @Binding var name: String
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Map name", text: $name)
                    .textInputAutocapitalization(.words)
                Text("The ARKit world map, exact 3D landmark snapshot, metadata, and one guide image are stored locally.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Save Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save", action: onSave)
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
