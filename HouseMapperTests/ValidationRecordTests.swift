import XCTest
@testable import HouseMapper

final class ValidationRecordTests: XCTestCase {
    func testSessionBenchmarkAccumulatorSeparatesSourceVisibilityAndDisplayCap() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var accumulator = SessionBenchmarkAccumulator(startedAt: startedAt)
        accumulator.recordFrame(
            timestamp: 10,
            cameraWidth: 1_920,
            cameraHeight: 1_440,
            trackingCategory: .normal
        )
        accumulator.recordFrame(
            timestamp: 10.5,
            cameraWidth: 1_920,
            cameraHeight: 1_440,
            trackingCategory: .limitedExcessiveMotion
        )
        accumulator.recordFeatureSnapshot(
            FeaturePointSnapshot(
                points: Array(repeating: ScreenFeaturePoint(id: 1, position: .zero, role: .scanning), count: 240),
                observedCount: 1_000,
                visibleCount: 500,
                rejectedBehindCameraCount: 200,
                rejectedInvalidProjectionCount: 50,
                rejectedOutsideViewportCount: 250,
                mapIdentityMatchCount: 20,
                timestamp: 10.5
            )
        )

        let report = accumulator.makeReport(
            mode: .mapping,
            completedAt: startedAt.addingTimeInterval(2),
            deviceModel: "iPhone17,1",
            systemVersion: "26.6",
            appVersion: "1.0"
        )

        XCTAssertEqual(report.runtime.frameCount, 2)
        XCTAssertEqual(report.runtime.effectiveFramesPerSecond, 2, accuracy: 0.0001)
        XCTAssertEqual(report.runtime.trackingSampleCount(for: .normal), 1)
        XCTAssertEqual(report.runtime.trackingSampleCount(for: .limitedExcessiveMotion), 1)
        XCTAssertEqual(report.features?.meanObservedCount, 1_000)
        XCTAssertEqual(report.features?.meanVisibleCount, 500)
        XCTAssertEqual(report.features?.meanDisplayedCount, 240)
        XCTAssertEqual(report.features?.displayCappedSampleCount, 1)
        XCTAssertEqual(report.features?.meanRejectedBehindCameraCount, 200)
        XCTAssertEqual(report.features?.meanRejectedInvalidProjectionCount, 50)
        XCTAssertEqual(report.features?.meanRejectedOutsideViewportCount, 250)
    }

    func testSessionBenchmarkReportRoundTripsAsJSON() throws {
        var accumulator = SessionBenchmarkAccumulator(
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        accumulator.recordFrame(
            timestamp: 1,
            cameraWidth: 1_920,
            cameraHeight: 1_440,
            trackingCategory: .normal
        )
        accumulator.recordDepth(
            DepthBenchmarkMetrics(width: 256, height: 192, highConfidenceFraction: 0.72)
        )
        accumulator.recordMap(
            MapBenchmarkMetrics(
                mapID: uuid(99),
                mapName: "Upstairs",
                landmarkCount: 12_000,
                meshAnchorCount: 8,
                meshVertexCount: 20_000,
                meshTriangleCount: 35_000,
                keyframeCount: 42,
                spatialMapByteCount: 4_000_000,
                packageByteCount: 6_000_000,
                ioDuration: 0.8
            )
        )
        let report = accumulator.makeReport(
            mode: .relocalization,
            completedAt: Date(timeIntervalSince1970: 1_012),
            deviceModel: "iPhone17,1",
            systemVersion: "26.6",
            appVersion: "1.0"
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(SessionBenchmarkReport.self, from: data)

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.depth?.highConfidenceFraction, 0.72)
        XCTAssertEqual(decoded.map?.meshTriangleCount, 35_000)
        XCTAssertEqual(decoded.map?.keyframeCount, 42)
    }

    func testZeroFeatureSamplesReduceMeanInsteadOfBeingDropped() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var accumulator = SessionBenchmarkAccumulator(startedAt: startedAt)
        accumulator.recordFeatureSnapshot(
            FeaturePointSnapshot(
                points: [],
                observedCount: 0,
                visibleCount: 0,
                rejectedBehindCameraCount: 0,
                rejectedOutsideViewportCount: 0,
                mapIdentityMatchCount: 0,
                timestamp: 1
            )
        )
        accumulator.recordFeatureSnapshot(
            FeaturePointSnapshot(
                points: [],
                observedCount: 1_000,
                visibleCount: 400,
                rejectedBehindCameraCount: 200,
                rejectedOutsideViewportCount: 400,
                mapIdentityMatchCount: 0,
                timestamp: 2
            )
        )

        let report = accumulator.makeReport(
            mode: .mapping,
            completedAt: startedAt.addingTimeInterval(2),
            deviceModel: "iPhone17,1",
            systemVersion: "26.6",
            appVersion: "1.0"
        )

        XCTAssertEqual(report.features?.sampleCount, 2)
        XCTAssertEqual(report.features?.meanObservedCount, 500)
        XCTAssertEqual(report.features?.meanVisibleCount, 200)
    }

    func testLegacyMapBenchmarkWithoutKeyframeCountDecodesAsZero() throws {
        let mapID = uuid(99)
        let json = """
        {
          "mapID": "\(mapID.uuidString)",
          "mapName": "Legacy",
          "landmarkCount": 100,
          "meshAnchorCount": 2,
          "meshVertexCount": 300,
          "meshTriangleCount": 500
        }
        """

        let decoded = try JSONDecoder().decode(
            MapBenchmarkMetrics.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.keyframeCount, 0)
        XCTAssertEqual(decoded.mapID, mapID)
    }

    func testRetentionKeepsNewestRecordsInDescendingOrder() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let records = [
            makeRecord(id: 1, completedAt: origin.addingTimeInterval(10)),
            makeRecord(id: 2, completedAt: origin.addingTimeInterval(30)),
            makeRecord(id: 3, completedAt: origin.addingTimeInterval(20))
        ]

        let retained = ValidationStore.retainedRecords(records, limit: 2)

        XCTAssertEqual(retained.map(\.id), [uuid(2), uuid(3)])
    }

    func testRetentionPrefersMostRecentlyAppendedRecordForEqualDates() {
        let date = Date(timeIntervalSince1970: 1_000)
        let records = [
            makeRecord(id: 1, completedAt: date),
            makeRecord(id: 2, completedAt: date),
            makeRecord(id: 3, completedAt: date)
        ]

        let retained = ValidationStore.retainedRecords(records, limit: 2)

        XCTAssertEqual(retained.map(\.id), [uuid(3), uuid(2)])
    }

    func testRetentionWithZeroLimitReturnsNoRecords() {
        let records = [makeRecord(id: 1, completedAt: Date())]

        XCTAssertTrue(ValidationStore.retainedRecords(records, limit: 0).isEmpty)
    }

    func testDurationCannotBeNegative() {
        let completedAt = Date(timeIntervalSince1970: 1_000)
        let record = ValidationRecord(
            id: uuid(1),
            mapID: uuid(99),
            mapName: "Upstairs",
            startedAt: completedAt.addingTimeInterval(5),
            completedAt: completedAt,
            outcome: .cancelled,
            startTrackingLabel: "Relocalizing",
            endTrackingLabel: "Relocalizing",
            startConfidenceLabel: "Low",
            endConfidenceLabel: "Low"
        )

        XCTAssertEqual(record.duration, 0)
    }

    func testRecordRoundTripsThroughJSON() throws {
        let completedAt = Date(timeIntervalSince1970: 1_020)
        let record = ValidationRecord(
            id: uuid(1),
            mapID: uuid(99),
            mapName: "Upstairs",
            startedAt: completedAt.addingTimeInterval(-20),
            completedAt: completedAt,
            outcome: .success,
            startTrackingLabel: "Relocalizing",
            endTrackingLabel: "Tracking in map",
            startConfidenceLabel: "Low",
            endConfidenceLabel: "High",
            finalPosition: ValidationPosition(x: 1, y: 2, z: 3),
            finalOrientation: ValidationOrientation(pitch: 0.1, yaw: 0.2, roll: 0.3),
            notes: "Started from the hallway."
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ValidationRecord.self, from: data)

        XCTAssertEqual(decoded, record)
    }

    private func makeRecord(id: UInt8, completedAt: Date) -> ValidationRecord {
        ValidationRecord(
            id: uuid(id),
            mapID: uuid(99),
            mapName: "Upstairs",
            startedAt: completedAt.addingTimeInterval(-8),
            completedAt: completedAt,
            outcome: .success,
            startTrackingLabel: "Relocalizing",
            endTrackingLabel: "Tracking in map",
            startConfidenceLabel: "Low",
            endConfidenceLabel: "High"
        )
    }

    private func uuid(_ finalByte: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, 0, 0, finalByte
        ))
    }
}
