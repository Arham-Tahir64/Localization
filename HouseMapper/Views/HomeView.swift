import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var mapLibrary: MapLibrary
    @State private var activeExperience: ActiveExperience?

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
                                Button {
                                    activeExperience = ActiveExperience(
                                        mode: .relocalization(package)
                                    )
                                } label: {
                                    MapRow(package: package)
                                }
                                .buttonStyle(.plain)
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
            .onAppear { mapLibrary.refresh() }
            .fullScreenCover(item: $activeExperience) { experience in
                ExperienceScreen(mode: experience.mode, mapLibrary: mapLibrary)
            }
        }
    }
}

private struct ActiveExperience: Identifiable {
    let id = UUID()
    let mode: ExperienceMode
}

private struct MapRow: View {
    let package: MapPackage

    var body: some View {
        HStack(spacing: 14) {
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
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var extentText: String {
        let extent = package.metadata.extent
        return String(format: "%.1f × %.1f m", extent.x, extent.z)
    }
}
