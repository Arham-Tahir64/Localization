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

    func testLoadSpatialMapReturnsExactStoredSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mapID = UUID()
        let snapshot = try SpatialMapSnapshot(
            mapID: mapID,
            landmarks: [
                SpatialLandmarkRecord(
                    id: 42,
                    position: Vector3Record(x: 1, y: 2, z: 3)
                )
            ]
        )
        _ = try writePackage(
            inside: fixture.maps,
            metadataID: mapID,
            featurePointCount: 1,
            spatialMap: try SpatialMapSnapshotCodec.encode(snapshot)
        )
        let library = MapLibrary(mapsDirectory: fixture.maps)
        let package = try XCTUnwrap(library.maps.first)

        let loaded = try await library.loadSpatialMap(from: package)

        XCTAssertEqual(loaded, snapshot)
    }

    func testLoadSpatialMapRejectsMetadataPayloadCountMismatch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mapID = UUID()
        let snapshot = try SpatialMapSnapshot(
            mapID: mapID,
            landmarks: [
                SpatialLandmarkRecord(
                    id: 42,
                    position: Vector3Record(x: 1, y: 2, z: 3)
                )
            ]
        )
        _ = try writePackage(
            inside: fixture.maps,
            metadataID: mapID,
            featurePointCount: 2,
            spatialMap: try SpatialMapSnapshotCodec.encode(snapshot)
        )
        let library = MapLibrary(mapsDirectory: fixture.maps)
        let package = try XCTUnwrap(library.maps.first)

        do {
            _ = try await library.loadSpatialMap(from: package)
            XCTFail("Expected a mismatched spatial payload to be rejected")
        } catch let error as MapLibraryError {
            guard case .spatialMapFeatureCountMismatch(expected: 2, actual: 1) = error else {
                return XCTFail("Unexpected map error: \(error)")
            }
        }
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
        preview: Data = Data("preview".utf8),
        featurePointCount: Int = 10,
        spatialMap: Data? = nil
    ) throws -> MapPackage {
        let directory = parent.appendingPathComponent(
            (directoryID ?? metadataID).uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let metadata = makeMetadata(
            id: metadataID,
            name: name,
            featurePointCount: featurePointCount
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent("metadata.json"),
            options: .atomic
        )
        try worldMap.write(to: directory.appendingPathComponent("worldmap.arexperience"))
        try preview.write(to: directory.appendingPathComponent("preview.jpg"))
        if let spatialMap {
            try spatialMap.write(to: directory.appendingPathComponent("spatial-map.plist"))
        }
        return MapPackage(metadata: metadata, directoryURL: directory)
    }

    private func makeMetadata(
        id: UUID,
        name: String,
        featurePointCount: Int
    ) -> MapMetadata {
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
            featurePointCount: featurePointCount,
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

final class SpatialMapSnapshotTests: XCTestCase {
    func testBinaryRoundTripPreservesMeshTransformTopologyAndClassification() throws {
        let mapID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let anchorID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let mesh = try SpatialMeshAnchorRecord(
            id: anchorID,
            mapFromAnchor: SpatialTransformRecord(
                values: [
                    1, 0, 0, 0,
                    0, 1, 0, 0,
                    0, 0, 1, 0,
                    4, 5, 6, 1
                ]
            ),
            vertices: [
                Vector3Record(x: 0, y: 0, z: 0),
                Vector3Record(x: 1, y: 0, z: 0),
                Vector3Record(x: 0, y: 1, z: 0)
            ],
            normals: [
                Vector3Record(x: 0, y: 0, z: 1),
                Vector3Record(x: 0, y: 0, z: 1),
                Vector3Record(x: 0, y: 0, z: 1)
            ],
            faces: [
                SpatialMeshFaceRecord(
                    firstVertexIndex: 0,
                    secondVertexIndex: 1,
                    thirdVertexIndex: 2,
                    classificationRawValue: 1
                )
            ]
        )
        let snapshot = try SpatialMapSnapshot(
            mapID: mapID,
            landmarks: [],
            meshAnchors: [mesh]
        )

        let decoded = try SpatialMapSnapshotCodec.decode(
            SpatialMapSnapshotCodec.encode(snapshot),
            expectedMapID: mapID
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.meshAnchors.first?.id, anchorID)
        XCTAssertEqual(decoded.meshAnchors.first?.faces.first?.classificationRawValue, 1)
    }

    func testDecodeAcceptsLegacyLandmarkOnlySnapshot() throws {
        struct LegacySnapshot: Codable {
            let schemaVersion: Int
            let mapID: UUID
            let landmarks: [SpatialLandmarkRecord]
            let bounds: SpatialBoundsRecord
        }
        let mapID = UUID()
        let legacy = LegacySnapshot(
            schemaVersion: 1,
            mapID: mapID,
            landmarks: [],
            bounds: SpatialBoundsRecord(
                minimum: Vector3Record(x: 0, y: 0, z: 0),
                maximum: Vector3Record(x: 0, y: 0, z: 0)
            )
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let decoded = try SpatialMapSnapshotCodec.decode(
            encoder.encode(legacy),
            expectedMapID: mapID
        )

        XCTAssertTrue(decoded.meshAnchors.isEmpty)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testMeshRejectsOutOfRangeTriangleIndex() {
        XCTAssertThrowsError(
            try SpatialMeshAnchorRecord(
                id: UUID(),
                mapFromAnchor: .identity,
                vertices: [Vector3Record(x: 0, y: 0, z: 0)],
                normals: [],
                faces: [
                    SpatialMeshFaceRecord(
                        firstVertexIndex: 0,
                        secondVertexIndex: 1,
                        thirdVertexIndex: 0,
                        classificationRawValue: nil
                    )
                ]
            )
        )
    }

    func testSnapshotRejectsDuplicateMeshAnchorIdentifiers() throws {
        let anchorID = UUID()
        let mesh = try SpatialMeshAnchorRecord(
            id: anchorID,
            mapFromAnchor: .identity,
            vertices: [],
            normals: [],
            faces: []
        )

        XCTAssertThrowsError(
            try SpatialMapSnapshot(
                mapID: UUID(),
                landmarks: [],
                meshAnchors: [mesh, mesh]
            )
        ) { error in
            XCTAssertEqual(
                error as? SpatialMapSnapshotError,
                .duplicateMeshAnchorIdentifier(anchorID)
            )
        }
    }

    func testBinaryRoundTripPreservesEveryLandmarkAndBounds() throws {
        let mapID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let landmarks = [
            SpatialLandmarkRecord(id: 10, position: Vector3Record(x: -2, y: 1, z: 4)),
            SpatialLandmarkRecord(id: 20, position: Vector3Record(x: 3, y: -1, z: 8)),
            SpatialLandmarkRecord(id: 30, position: Vector3Record(x: 0, y: 5, z: -6))
        ]
        let snapshot = try SpatialMapSnapshot(mapID: mapID, landmarks: landmarks)

        let encoded = try SpatialMapSnapshotCodec.encode(snapshot)
        let decoded = try SpatialMapSnapshotCodec.decode(encoded, expectedMapID: mapID)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.landmarks, landmarks)
        XCTAssertEqual(decoded.bounds.minimum, Vector3Record(x: -2, y: -1, z: -6))
        XCTAssertEqual(decoded.bounds.maximum, Vector3Record(x: 3, y: 5, z: 8))
    }

    func testDecodeRejectsSnapshotBelongingToAnotherMap() throws {
        let storedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let requestedID = UUID(uuidString: "00000000-1111-2222-3333-444444444444")!
        let snapshot = try SpatialMapSnapshot(
            mapID: storedID,
            landmarks: [
                SpatialLandmarkRecord(
                    id: 1,
                    position: Vector3Record(x: 0, y: 0, z: 0)
                )
            ]
        )

        let encoded = try SpatialMapSnapshotCodec.encode(snapshot)

        XCTAssertThrowsError(
            try SpatialMapSnapshotCodec.decode(encoded, expectedMapID: requestedID)
        )
    }

    func testSnapshotRejectsDuplicateLandmarkIdentifiers() {
        XCTAssertThrowsError(
            try SpatialMapSnapshot(
                mapID: UUID(),
                landmarks: [
                    SpatialLandmarkRecord(
                        id: 7,
                        position: Vector3Record(x: 0, y: 0, z: 0)
                    ),
                    SpatialLandmarkRecord(
                        id: 7,
                        position: Vector3Record(x: 1, y: 1, z: 1)
                    )
                ]
            )
        )
    }
}
