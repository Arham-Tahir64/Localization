import XCTest
@testable import HouseMapper

final class ValidationRecordTests: XCTestCase {
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
