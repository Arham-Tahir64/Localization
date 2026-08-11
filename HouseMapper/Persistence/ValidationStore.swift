import Combine
import Foundation

@MainActor
final class ValidationStore: ObservableObject {
    static let defaultMaximumRecordCount = 100

    @Published private(set) var records: [ValidationRecord] = []
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let maximumRecordCount: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        maximumRecordCount: Int = ValidationStore.defaultMaximumRecordCount
    ) {
        precondition(maximumRecordCount >= 0, "maximumRecordCount cannot be negative")

        self.fileManager = fileManager
        let applicationSupport = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.directoryURL = applicationSupport.appendingPathComponent(
            "HouseMapper",
            isDirectory: true
        )
        fileURL = self.directoryURL.appendingPathComponent("validation-history.json")
        self.maximumRecordCount = maximumRecordCount

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        refresh()
    }

    func refresh() {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            guard fileManager.fileExists(atPath: fileURL.path) else {
                records = []
                lastError = nil
                return
            }

            let data = try Data(contentsOf: fileURL)
            let decodedRecords = try decoder.decode([ValidationRecord].self, from: data)
            let retainedRecords = Self.retainedRecords(
                decodedRecords,
                limit: maximumRecordCount
            )
            if retainedRecords.count != decodedRecords.count {
                records = retainedRecords
                persist(retainedRecords)
                return
            }
            records = retainedRecords
            lastError = nil
        } catch {
            records = []
            lastError = error.localizedDescription
        }
    }

    func append(_ record: ValidationRecord) {
        let updatedRecords = Self.retainedRecords(
            records + [record],
            limit: maximumRecordCount
        )
        persist(updatedRecords)
    }

    func clear() {
        persist([])
    }

    nonisolated static func retainedRecords(
        _ records: [ValidationRecord],
        limit: Int
    ) -> [ValidationRecord] {
        guard limit > 0 else { return [] }

        return records.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.completedAt == rhs.element.completedAt {
                    return lhs.offset > rhs.offset
                }
                return lhs.element.completedAt > rhs.element.completedAt
            }
            .prefix(limit)
            .map(\.element)
    }

    private func persist(_ updatedRecords: [ValidationRecord]) {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(updatedRecords)
            try data.write(to: fileURL, options: .atomic)
            records = updatedRecords
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
