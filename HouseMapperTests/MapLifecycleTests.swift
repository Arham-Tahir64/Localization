import XCTest
@testable import HouseMapper

@MainActor
final class MapLifecycleTests: XCTestCase {
    func testRenameUpdatesOnlyMetadataAndRetainsPackageIdentityAndAssets() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let originalArchive = Data("world-map".utf8)
        let originalPreview = Data("preview".utf8)
        let original = try writePackage(
            inside: fixture.maps,
            worldMap: originalArchive,
            preview: originalPreview
        )
        let library = MapLibrary(mapsDirectory: fixture.maps)
        let discovered = try XCTUnwrap(library.maps.first)

        let renamed = try await library.rename(discovered, to: "  Upstairs  ")

        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.directoryURL, original.directoryURL)
        XCTAssertEqual(renamed.metadata.name, "Upstairs")
        XCTAssertGreaterThan(renamed.metadata.updatedAt, original.metadata.updatedAt)
        XCTAssertEqual(try Data(contentsOf: renamed.worldMapURL), originalArchive)
        XCTAssertEqual(try Data(contentsOf: renamed.previewURL), originalPreview)

        let storedMetadata = try decodeMetadata(
            at: renamed.directoryURL.appendingPathComponent("metadata.json")
        )
        XCTAssertEqual(storedMetadata.id, original.id)
        XCTAssertEqual(storedMetadata.name, "Upstairs")
    }

    func testDeleteRejectsNestedAndMismatchedUUIDDirectories() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let library = MapLibrary(mapsDirectory: fixture.maps)

        let nestedParent = fixture.maps.appendingPathComponent("Nested", isDirectory: true)
        let nested = try writePackage(inside: nestedParent)
        await assertDeleteFails(nested, with: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.directoryURL.path))

        let metadataID = UUID()
        let mismatched = try writePackage(
            inside: fixture.maps,
            metadataID: metadataID,
            directoryID: UUID()
        )
        await assertDeleteFails(mismatched, with: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatched.directoryURL.path))
    }

    func testDeleteRemovesTheExplicitValidPackageOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = try writePackage(inside: fixture.maps, name: "Selected")
        let retained = try writePackage(inside: fixture.maps, name: "Retained")
        let library = MapLibrary(mapsDirectory: fixture.maps)

        try await library.delete(selected)

        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.directoryURL.path))
        XCTAssertEqual(library.maps.map(\.id), [retained.id])
    }

    func testRefreshPublishesPackageSizeFromFileResourceValues() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try writePackage(
            inside: fixture.maps,
            worldMap: Data(repeating: 1, count: 2_048),
            preview: Data(repeating: 2, count: 1_024)
        )
        let library = MapLibrary(mapsDirectory: fixture.maps)

        for _ in 0..<100 where library.maps.first?.sizeInBytes == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let size = try XCTUnwrap(library.maps.first?.sizeInBytes)
        XCTAssertGreaterThanOrEqual(size, 3_072)
        XCTAssertEqual(library.maps.first?.id, package.id)
    }

    private func makeFixture() throws -> (root: URL, maps: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        let maps = root.appendingPathComponent("Maps", isDirectory: true)
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        return (root, maps)
    }

    private func writePackage(
        inside parent: URL,
        name: String = "Original",
        metadataID: UUID = UUID(),
        directoryID: UUID? = nil,
        worldMap: Data = Data("world-map".utf8),
        preview: Data = Data("preview".utf8)
    ) throws -> MapPackage {
        let directory = parent.appendingPathComponent(
            (directoryID ?? metadataID).uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let metadata = makeMetadata(id: metadataID, name: name)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent("metadata.json"),
            options: .atomic
        )
        try worldMap.write(to: directory.appendingPathComponent("worldmap.arexperience"))
        try preview.write(to: directory.appendingPathComponent("preview.jpg"))
        return MapPackage(metadata: metadata, directoryURL: directory)
    }

    private func makeMetadata(id: UUID, name: String) -> MapMetadata {
        MapMetadata(
            schemaVersion: MapMetadata.currentSchemaVersion,
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

    private func decodeMetadata(at url: URL) throws -> MapMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MapMetadata.self, from: Data(contentsOf: url))
    }

    private func assertDeleteFails(
        _ package: MapPackage,
        with library: MapLibrary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await library.delete(package)
            XCTFail("Expected delete to reject an unsafe package path", file: file, line: line)
        } catch {
            // Any validation failure is sufficient; the survival assertion verifies safety.
        }
    }
}
