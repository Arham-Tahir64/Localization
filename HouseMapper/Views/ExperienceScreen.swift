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
            ARSceneView(controller: controller)
                .ignoresSafeArea()

            SpatialFeatureOverlay(snapshot: controller.featurePointSnapshot)
                .ignoresSafeArea()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.72), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 10) {
                cameraHeader

                if case .mapping = mode {
                    ProgressView(value: controller.mappingProgress)
                        .tint(experienceColor)
                        .scaleEffect(y: 0.55)
                        .padding(.horizontal, 52)
                        .accessibilityLabel("Mapping progress")
                }

                if case .relocalization(let package) = mode,
                   controller.phase != .tracking {
                    HStack {
                        Spacer()
                        RelocalizationReferenceThumbnail(package: package)
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    SpatialScanReticle(
                        color: experienceColor,
                        isActive: isScanReticleActive
                    )

                    SpatialGuidancePrompt(
                        title: guidanceTitle,
                        detail: guidanceDetail,
                        color: experienceColor
                    )
                }

                Spacer()

                HStack(spacing: 10) {
                    MapOverviewView(
                        map: controller.mapRenderSnapshot,
                        mesh: controller.meshRenderSnapshot,
                        trail: controller.trail,
                        pose: controller.pose,
                        accentColor: experienceColor
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 116)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapPanelTitle)
                                .font(.caption2.bold())
                                .tracking(0.7)
                            Text(mapPanelCount)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.56))
                            .padding(12)
                    }

                    PoseInstrumentView(
                        pose: controller.pose,
                        accentColor: experienceColor
                    )
                    .frame(maxWidth: .infinity)
                }

                controls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if controller.phase == .tracking {
                LocalizationSuccessPulse()
                    .transition(.opacity)
            }
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

    private var cameraHeader: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.bold())
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.58), in: Circle())
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }
            .accessibilityLabel("Close spatial session")

            SpatialStatusCapsule(
                title: statusTitle,
                detail: "\(controller.trackingDescription) • \(controller.captureDescription)",
                featureCount: controller.featurePointSnapshot.displayedCount,
                visibleFeatureCount: controller.featurePointSnapshot.visibleCount,
                sourceFeatureCount: controller.featurePointSnapshot.observedCount,
                matchCount: controller.featurePointSnapshot.mapIdentityMatchCount,
                color: experienceColor
            )
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

    private var isScanReticleActive: Bool {
        switch controller.phase {
        case .tracking, .failed, .unsupported:
            return false
        default:
            return true
        }
    }

    private var guidanceTitle: String {
        switch mode {
        case .mapping:
            return controller.mappingDescription == "Mapped"
                ? "Map coverage is ready"
                : "Scan architectural detail"
        case .relocalization:
            switch controller.phase {
            case .tracking: return "Localized in saved map"
            case .failed: return "Move to a distinctive mapped area"
            case .limited: return "Hold steady and find more texture"
            case .loading: return "Preparing saved spatial map"
            default: return "Matching this view to your map"
            }
        }
    }

    private var guidanceDetail: String {
        if let message = controller.statusMessage, controller.phase != .tracking {
            return message
        }
        switch mode {
        case .mapping:
            return controller.mappingDescription == "Mapped"
                ? "Save now, or continue walking to extend into another room."
                : "Move slowly across corners, door frames, walls, and fixed objects."
        case .relocalization:
            if controller.phase == .tracking {
                return "Green points are restored saved-map landmark IDs after pose lock."
            }
            return "White points are live features; exact saved-ID overlaps turn green."
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch mode {
        case .mapping:
            Button {
                showingSaveDialog = true
            } label: {
                Label(
                    controller.isSaving ? "Saving…" : "Save Map",
                    systemImage: "square.and.arrow.down"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .clipShape(Capsule())
            .disabled(!controller.canSave || controller.isSaving)

        case .relocalization:
            if controller.phase == .failed || controller.phase == .limited {
                Button {
                    beginValidationAttemptIfNeeded(forceNewAttempt: true)
                    controller.retryRelocalization()
                } label: {
                    Label("Retry Saved Map", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .clipShape(Capsule())
            } else if controller.phase == .tracking {
                Label("Pose locked in saved map", systemImage: "location.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(.green.opacity(0.12), in: Capsule())
                    .overlay {
                        Capsule().stroke(.green.opacity(0.28), lineWidth: 1)
                    }
            } else {
                HStack(spacing: 7) {
                    ProgressView()
                        .tint(experienceColor)
                    Text("\(Int(controller.elapsedRelocalization)) s · \(controller.confidence.rawValue) confidence")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, minHeight: 40)
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
private struct RelocalizationReferenceThumbnail: View {
    let package: MapPackage

    var body: some View {
        HStack(spacing: 9) {
            if let image = UIImage(contentsOfFile: package.previewURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("REFERENCE")
                    .font(.caption2.bold())
                    .tracking(0.7)
                Text(package.metadata.name)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
            }
        }
        .padding(7)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
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
