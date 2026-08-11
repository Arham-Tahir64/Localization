import SwiftUI
import UIKit

struct ExperienceScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ARSessionController
    @State private var mapName = "My House"
    @State private var showingSaveDialog = false
    @State private var showingSavedAlert = false

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

            LinearGradient(
                colors: [.black.opacity(0.68), .clear, .black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                header
                statusPanel

                Spacer()

                if case .relocalization(let package) = mode,
                   controller.phase != .tracking {
                    RelocalizationGuide(package: package)
                }

                MapOverviewView(
                    mapPoints: controller.mapPoints,
                    trail: controller.trail,
                    pose: controller.pose
                )
                .frame(height: 185)

                controls
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onDisappear { controller.stop() }
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

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.headline)
                Text(controller.phase.rawValue)
                    .font(.caption)
                    .foregroundStyle(phaseColor)
            }
            Spacer()
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                StatusItem(title: "Tracking", value: controller.trackingDescription)
                Spacer()
                if case .relocalization = mode {
                    Label(controller.confidence.rawValue, systemImage: controller.confidence.symbolName)
                        .font(.caption.bold())
                        .foregroundStyle(confidenceColor)
                }
            }

            if case .mapping = mode {
                ProgressView(value: controller.mappingProgress)
                    .tint(.cyan)
                HStack {
                    StatusItem(title: "Map", value: controller.mappingDescription)
                    Spacer()
                    StatusItem(title: "Features", value: controller.featurePointCount.formatted())
                }
            } else if controller.phase != .tracking {
                Text("Elapsed: \(Int(controller.elapsedRelocalization)) s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(controller.depthDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(controller.meshDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let pose = controller.pose {
                PoseReadout(pose: pose)
            } else if case .relocalization = mode {
                Text("Map pose withheld until the saved map is matched.")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            if let message = controller.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
            .disabled(!controller.canSave || controller.isSaving)

        case .relocalization:
            if controller.phase == .failed || controller.phase == .limited {
                Button {
                    controller.retryRelocalization()
                } label: {
                    Label("Retry Saved Map", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Confidence is a conservative app status, not a statistical error bound.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .tracking, .mapping: return .green
        case .failed, .unsupported: return .red
        default: return .orange
        }
    }

    private var confidenceColor: Color {
        switch controller.confidence {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .orange
        case .unavailable: return .secondary
        }
    }
}

private struct StatusItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
        }
    }
}

private struct PoseReadout: View {
    let pose: CameraPose

    var body: some View {
        let position = pose.position
        let radiansToDegrees = Float(180 / Double.pi)
        VStack(alignment: .leading, spacing: 3) {
            Text(String(
                format: "Map XYZ   %+.2f  %+.2f  %+.2f m",
                position.x,
                position.y,
                position.z
            ))
            Text(String(
                format: "Pitch/Yaw/Roll   %+.1f°  %+.1f°  %+.1f°",
                pose.eulerAngles.x * radiansToDegrees,
                pose.eulerAngles.y * radiansToDegrees,
                pose.eulerAngles.z * radiansToDegrees
            ))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
    }
}

private struct RelocalizationGuide: View {
    let package: MapPackage

    var body: some View {
        HStack(spacing: 12) {
            if let image = UIImage(contentsOfFile: package.previewURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Find mapped visual detail")
                    .font(.subheadline.bold())
                Text("Move slowly; include nearby objects and wall texture from several angles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                Text("Only ARKit's persistent map, compact metadata, and one guide image are stored.")
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
