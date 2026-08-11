import Foundation
import XCTest
@testable import HouseMapper

@MainActor
final class PersistenceBenchmarkTests: XCTestCase {
    func testRefreshEnumeratesOnlyCompleteSupportedUUIDPackages() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let valid = try writePackage(inside: fixture.maps, name: "Valid")
        _ = try writePackage(
            inside: fixture.maps,
            metadataID: UUID(),
            directoryID: UUID(),
            name: "Mismatched"
        )
        _ = try writePackage(
            inside: fixture.maps,
            name: "Future schema",
            schemaVersion: MapMetadata.currentSchemaVersion + 1
        )
        let incomplete = fixture.maps.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: incomplete.appendingPathComponent("metadata.json"))

        let library = MapLibrary(mapsDirectory: fixture.maps)

        XCTAssertEqual(library.maps.map(\.id), [valid.id])
        XCTAssertNil(library.lastError)
    }

    func testSymlinkedPackageIsNotDiscoveredAndCannotMutateExternalPackage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let external = try writePackage(inside: fixture.external, name: "External")
        let link = fixture.maps.appendingPathComponent(external.id.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external.directoryURL)
        let library = MapLibrary(mapsDirectory: fixture.maps)
        let forged = MapPackage(metadata: external.metadata, directoryURL: link)

        XCTAssertTrue(library.maps.isEmpty)
        await assertRenameFails(forged, with: library)
        await assertDeleteFails(forged, with: library)
        await assertLoadFails(forged, with: library)

        XCTAssertEqual(try decodeMetadata(at: external.directoryURL.appendingPathComponent("metadata.json")).name, "External")
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.worldMapURL.path))
    }

    func testFailedRenameLeavesStoredMetadataUntouched() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let package = try writePackage(inside: fixture.maps, name: "Original")
        let badPackage = MapPackage(
            metadata: makeMetadata(id: UUID(), name: "Forged"),
            directoryURL: package.directoryURL
        )
        let library = MapLibrary(mapsDirectory: fixture.maps)

        await assertRenameFails(badPackage, with: library)

        let stored = try decodeMetadata(at: package.directoryURL.appendingPathComponent("metadata.json"))
        XCTAssertEqual(stored.name, "Original")
        XCTAssertEqual(stored.id, package.id)
    }

    func testRapidRefreshLeavesLatestSnapshotAndEventuallyLoadsItsSize() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for index in 0..<24 {
            _ = try writePackage(
                inside: fixture.maps,
                name: "Old \(index)",
                worldMap: Data(repeating: UInt8(index), count: 32 * 1_024)
            )
        }
        let library = MapLibrary(mapsDirectory: fixture.maps)
        library.refresh()
        library.refresh()

        let oldDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.maps,
            includingPropertiesForKeys: nil
        )
        for directory in oldDirectories {
            try FileManager.default.removeItem(at: directory)
        }
        let current = try writePackage(
            inside: fixture.maps,
            name: "Current",
            worldMap: Data(repeating: 7, count: 256 * 1_024),
            preview: Data(repeating: 8, count: 64 * 1_024)
        )
        library.refresh()

        for _ in 0..<100 where library.maps.first?.sizeInBytes == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(library.maps.map(\.id), [current.id])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(library.maps.first?.sizeInBytes), 320 * 1_024)
    }

    func testMappedDataReadRoundTripsSyntheticLargeArchive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let archiveURL = fixture.root.appendingPathComponent("synthetic.arexperience")
        let expected = Data((0..<(8 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        try expected.write(to: archiveURL, options: .atomic)

        let mappedIfSafe = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        XCTAssertEqual(mappedIfSafe.count, expected.count)
        XCTAssertEqual(mappedIfSafe, expected)
    }

    func testValidationStoreRecoversFromMalformedHistoryOnNextAppend() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let historyDirectory = fixture.root.appendingPathComponent("HouseMapper", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let historyURL = historyDirectory.appendingPathComponent("validation-history.json")
        try Data("truncated [".utf8).write(to: historyURL, options: .atomic)

        let store = ValidationStore(directoryURL: fixture.root, maximumRecordCount: 3)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastError)

        let record = makeRecord(id: 1, completedAt: Date(timeIntervalSince1970: 1_000))
        store.append(record)
        let reloaded = ValidationStore(directoryURL: fixture.root, maximumRecordCount: 3)
        XCTAssertEqual(reloaded.records, [record])
        XCTAssertNil(reloaded.lastError)
    }

    func testValidationRetentionHasDeterministicBoundAtLargeSyntheticInput() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let records = (0..<10_000).map { index in
            makeRecord(
                id: UInt8(index % 250),
                completedAt: origin.addingTimeInterval(TimeInterval(index / 2))
            )
        }

        let retained = ValidationStore.retainedRecords(records, limit: 100)

        XCTAssertEqual(retained.count, 100)
        XCTAssertTrue(zip(retained, retained.dropFirst()).allSatisfy { $0.completedAt >= $1.completedAt })
        XCTAssertEqual(retained.first?.completedAt, origin.addingTimeInterval(4_999))
    }

    func testPerformanceRefreshOfSyntheticPackageLibrary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for index in 0..<100 {
            _ = try writePackage(
                inside: fixture.maps,
                name: "Package \(index)",
                worldMap: Data(repeating: UInt8(index), count: 8 * 1_024),
                preview: nil
            )
        }

        measure(metrics: [XCTClockMetric()]) {
            let library = MapLibrary(mapsDirectory: fixture.maps)
            library.refresh()
            XCTAssertEqual(library.maps.count, 100)
        }
    }

    func testPerformanceRetentionOfSyntheticHistory() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let records = (0..<10_000).map { index in
            makeRecord(
                id: UInt8(index % 250),
                completedAt: origin.addingTimeInterval(TimeInterval(index))
            )
        }

        measure(metrics: [XCTClockMetric()]) {
            XCTAssertEqual(ValidationStore.retainedRecords(records, limit: 100).count, 100)
        }
    }

    private func makeFixture() throws -> (root: URL, maps: URL, external: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceBenchmarkTests-\(UUID().uuidString)", isDirectory: true)
        let maps = root.appendingPathComponent("Maps", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        return (root, maps, external)
    }

    private func writePackage(
        inside parent: URL,
        metadataID: UUID = UUID(),
        directoryID: UUID? = nil,
        name: String,
        schemaVersion: Int = MapMetadata.currentSchemaVersion,
        worldMap: Data = Data("world-map".utf8),
        preview: Data? = Data("preview".utf8)
    ) throws -> MapPackage {
        let directory = parent.appendingPathComponent(
            (directoryID ?? metadataID).uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = makeMetadata(id: metadataID, name: name, schemaVersion: schemaVersion)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent("metadata.json"),
            options: .atomic
        )
        try worldMap.write(to: directory.appendingPathComponent("worldmap.arexperience"), options: .atomic)
        if let preview {
            try preview.write(to: directory.appendingPathComponent("preview.jpg"), options: .atomic)
        }
        return MapPackage(metadata: metadata, directoryURL: directory)
    }

    private func makeMetadata(
        id: UUID,
        name: String,
        schemaVersion: Int = MapMetadata.currentSchemaVersion
    ) -> MapMetadata {
        MapMetadata(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "1.0",
            systemVersion: "test",
            deviceModel: "test",
            backend: "ARWorldMap",
            center: Vector3Record(x: 0, y: 0, z: 0),
            extent: Vector3Record(x: 1, y: 1, z: 1),
            featurePointCount: 10,
            hasSceneDepth: true,
            hasSceneReconstruction: true
        )
    }

    private func makeRecord(id: UInt8, completedAt: Date) -> ValidationRecord {
        ValidationRecord(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, id)),
            mapID: UUID(),
            mapName: "Synthetic",
            startedAt: completedAt.addingTimeInterval(-1),
            completedAt: completedAt,
            outcome: .success,
            startTrackingLabel: "Normal",
            endTrackingLabel: "Normal",
            startConfidenceLabel: "High",
            endConfidenceLabel: "High"
        )
    }

    private func decodeMetadata(at url: URL) throws -> MapMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MapMetadata.self, from: Data(contentsOf: url))
    }

    private func assertRenameFails(
        _ package: MapPackage,
        with library: MapLibrary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await library.rename(package, to: "Forbidden")
            XCTFail("Expected rename to reject an unsafe package", file: file, line: line)
        } catch {
            // The subsequent storage assertion verifies failure recovery.
        }
    }

    private func assertDeleteFails(
        _ package: MapPackage,
        with library: MapLibrary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await library.delete(package)
            XCTFail("Expected delete to reject an unsafe package", file: file, line: line)
        } catch {
            // The subsequent storage assertion verifies failure recovery.
        }
    }

    private func assertLoadFails(
        _ package: MapPackage,
        with library: MapLibrary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await library.loadWorldMap(from: package)
            XCTFail("Expected load to reject an unsafe package", file: file, line: line)
        } catch {
            // The subsequent storage assertion verifies failure recovery.
        }
    }
}
