import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var mapLibrary: MapLibrary
    @EnvironmentObject private var validationStore: ValidationStore
    @State private var activeExperience: ActiveExperience?
    @State private var mapPendingRename: MapPackage?
    @State private var renameDraft = ""
    @State private var mapPendingDeletion: MapPackage?
    @State private var operationError: MapOperationError?
    @State private var mapsBeingUpdated: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Persistent indoor maps")
                            .font(.largeTitle.bold())
                        Text("Scan with this iPhone, save locally, then reopen a map to recover a 6DoF pose without GPS or internet.")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        activeExperience = ActiveExperience(mode: .mapping)
                    } label: {
                        Label("Create New Map", systemImage: "viewfinder.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Saved maps")
                            .font(.title2.bold())

                        if mapLibrary.maps.isEmpty {
                            ContentUnavailableView(
                                "No saved maps",
                                systemImage: "map",
                                description: Text("Create a map and scan connected rooms before saving.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            ForEach(mapLibrary.maps) { package in
                                MapRow(
                                    package: package,
                                    isBeingUpdated: mapsBeingUpdated.contains(package.id),
                                    onOpen: { open(package) },
                                    onRename: { beginRenaming(package) },
                                    onDelete: { mapPendingDeletion = package }
                                )
                            }
                        }
                    }

                    if let error = mapLibrary.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
            }
            .navigationTitle("HouseMapper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ValidationHistoryView(
                            records: validationStore.records,
                            onClear: validationStore.clear
                        )
                    } label: {
                        Label("Validation History", systemImage: "chart.xyaxis.line")
                    }
                }
            }
            .onAppear { mapLibrary.refresh() }
            .fullScreenCover(item: $activeExperience) { experience in
                ExperienceScreen(mode: experience.mode, mapLibrary: mapLibrary)
            }
            .alert("Rename Map", isPresented: isRenamePresented) {
                TextField("Map name", text: $renameDraft)
                Button("Cancel", role: .cancel) {
                    mapPendingRename = nil
                }
                Button("Save") {
                    guard let package = mapPendingRename else { return }
                    mapPendingRename = nil
                    rename(package, to: renameDraft)
                }
            } message: {
                Text("Choose a name that makes this saved location easy to recognize.")
            }
            .confirmationDialog(
                "Delete saved map?",
                isPresented: isDeletePresented,
                titleVisibility: .visible,
                presenting: mapPendingDeletion
            ) { package in
                Button("Delete “\(package.metadata.name)”", role: .destructive) {
                    mapPendingDeletion = nil
                    delete(package)
                }
                Button("Cancel", role: .cancel) {
                    mapPendingDeletion = nil
                }
            } message: { package in
                Text("This permanently removes “\(package.metadata.name)” and its local AR world map.")
            }
            .alert(item: $operationError) { error in
                Alert(
                    title: Text("Map Update Failed"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { mapPendingRename != nil },
            set: { isPresented in
                if !isPresented { mapPendingRename = nil }
            }
        )
    }

    private var isDeletePresented: Binding<Bool> {
        Binding(
            get: { mapPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { mapPendingDeletion = nil }
            }
        )
    }

    private func open(_ package: MapPackage) {
        activeExperience = ActiveExperience(mode: .relocalization(package))
    }

    private func beginRenaming(_ package: MapPackage) {
        renameDraft = package.metadata.name
        mapPendingRename = package
    }

    private func rename(_ package: MapPackage, to name: String) {
        mapsBeingUpdated.insert(package.id)
        Task {
            defer { mapsBeingUpdated.remove(package.id) }
            do {
                try await mapLibrary.rename(package, to: name)
            } catch {
                operationError = MapOperationError(message: error.localizedDescription)
            }
        }
    }

    private func delete(_ package: MapPackage) {
        mapsBeingUpdated.insert(package.id)
        Task {
            defer { mapsBeingUpdated.remove(package.id) }
            do {
                try await mapLibrary.delete(package)
            } catch {
                operationError = MapOperationError(message: error.localizedDescription)
            }
        }
    }
}

private struct ActiveExperience: Identifiable {
    let id = UUID()
    let mode: ExperienceMode
}

private struct MapOperationError: Identifiable {
    let id = UUID()
    let message: String
}

private struct MapRow: View {
    let package: MapPackage
    let isBeingUpdated: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    preview
                    details
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isBeingUpdated)

            if isBeingUpdated {
                ProgressView()
                    .frame(width: 36, height: 44)
            } else {
                Menu {
                    ShareLink(item: package.directoryURL) {
                        Label("Share Calibrated Map Package", systemImage: "shippingbox.and.arrow.backward")
                    }
                    if FileManager.default.fileExists(atPath: package.benchmarkURL.path) {
                        ShareLink(item: package.benchmarkURL) {
                            Label("Share Device Benchmark", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(action: onRename) {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Actions for \(package.metadata.name)")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var preview: some View {
        Group {
            if let image = UIImage(contentsOfFile: package.previewURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "map.fill")
                    .font(.title)
                    .foregroundStyle(.cyan)
            }
        }
        .frame(width: 76, height: 76)
        .background(.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(package.metadata.name)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(package.metadata.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(package.metadata.featurePointCount.formatted()) features • \(extentText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(packageSizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var extentText: String {
        let extent = package.metadata.extent
        return String(format: "%.1f × %.1f m", extent.x, extent.z)
    }

    private var packageSizeText: String {
        guard let sizeInBytes = package.sizeInBytes else {
            return "Calculating package size…"
        }
        return "\(ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)) on device"
    }
}
