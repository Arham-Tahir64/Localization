import SwiftUI

struct ValidationHistoryView: View {
    let records: [ValidationRecord]
    let onClear: () -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "No validation attempts",
                    systemImage: "checkmark.seal",
                    description: Text("Relocalization attempts will appear here after you test a saved map.")
                )
            } else {
                List(records) { record in
                    NavigationLink {
                        ValidationDetailView(record: record)
                    } label: {
                        ValidationHistoryRow(record: record)
                    }
                }
            }
        }
        .navigationTitle("Validation History")
        .toolbar {
            if !records.isEmpty {
                Button("Clear", role: .destructive) {
                    isConfirmingClear = true
                }
            }
        }
        .confirmationDialog(
            "Clear validation history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive, action: onClear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all recorded validation attempts from this device.")
        }
    }
}

private struct ValidationHistoryRow: View {
    let record: ValidationRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.outcome.symbolName)
                .font(.title2)
                .foregroundStyle(record.outcome == .success ? .green : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.mapName)
                    .font(.headline)
                Text(record.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(record.outcome.title) • \(record.duration.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ValidationDetailView: View {
    let record: ValidationRecord

    var body: some View {
        List {
            Section("Attempt") {
                LabeledContent("Map", value: record.mapName)
                LabeledContent("Outcome", value: record.outcome.title)
                LabeledContent(
                    "Started",
                    value: record.startedAt.formatted(date: .abbreviated, time: .standard)
                )
                LabeledContent(
                    "Duration",
                    value: "\(record.duration.formatted(.number.precision(.fractionLength(1)))) s"
                )
            }

            Section("Tracking") {
                LabeledContent("Start", value: record.startTrackingLabel)
                LabeledContent("End", value: record.endTrackingLabel)
                LabeledContent("Start confidence", value: record.startConfidenceLabel)
                LabeledContent("End confidence", value: record.endConfidenceLabel)
            }

            if record.finalPosition != nil || record.finalOrientation != nil {
                Section("Final pose") {
                    if let position = record.finalPosition {
                        LabeledContent("Position (m)", value: vectorText(position))
                    }
                    if let orientation = record.finalOrientation {
                        LabeledContent("Pitch / yaw / roll", value: angleText(orientation))
                    }
                }
            }

            if let notes = record.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }
        }
        .navigationTitle("Validation Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func vectorText(_ position: ValidationPosition) -> String {
        String(format: "%.2f, %.2f, %.2f", position.x, position.y, position.z)
    }

    private func angleText(_ orientation: ValidationOrientation) -> String {
        String(
            format: "%.1f°, %.1f°, %.1f°",
            orientation.pitch * 180 / .pi,
            orientation.yaw * 180 / .pi,
            orientation.roll * 180 / .pi
        )
    }
}
