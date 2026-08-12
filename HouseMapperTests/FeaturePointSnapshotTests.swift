import XCTest
@testable import HouseMapper

final class FeaturePointSnapshotTests: XCTestCase {
    func testCaptureDiagnosticsMeasuresDeliveredFrameRateAndResolution() throws {
        var accumulator = CaptureDiagnosticsAccumulator(publicationInterval: 1)
        var published: CaptureDiagnosticsSnapshot?

        for frame in 0...60 {
            if let snapshot = accumulator.record(
                timestamp: Double(frame) / 60,
                imageWidth: 1_920,
                imageHeight: 1_440
            ) {
                published = snapshot
            }
        }

        let snapshot = try XCTUnwrap(published)
        XCTAssertEqual(snapshot.imageWidth, 1_920)
        XCTAssertEqual(snapshot.imageHeight, 1_440)
        XCTAssertEqual(snapshot.framesPerSecond, 60, accuracy: 0.01)
        XCTAssertEqual(snapshot.description, "1920×1440 • 60 fps")
    }

    func testCaptureDiagnosticsResetsAfterNonMonotonicTimestamp() {
        var accumulator = CaptureDiagnosticsAccumulator(publicationInterval: 1)

        XCTAssertNil(accumulator.record(timestamp: 10, imageWidth: 1_920, imageHeight: 1_440))
        XCTAssertNil(accumulator.record(timestamp: 9, imageWidth: 1_920, imageHeight: 1_440))
        XCTAssertNil(accumulator.record(timestamp: 9.5, imageWidth: 1_920, imageHeight: 1_440))

        let snapshot = accumulator.record(timestamp: 10, imageWidth: 1_920, imageHeight: 1_440)
        XCTAssertEqual(snapshot?.framesPerSecond ?? 0, 2, accuracy: 0.01)
    }

    func testMappingLandmarkAccumulatorRetainsUpdatesAndEvictsOldestRealLandmark() {
        var accumulator = MappingLandmarkAccumulator(maximumRetainedLandmarks: 3)
        accumulator.integrate(
            points: [SIMD3(0, 0, 0), SIMD3(1, 1, 1)],
            identifiers: [1, 2]
        )
        accumulator.integrate(
            points: [SIMD3(2, 2, 2), SIMD3(3, 3, 3)],
            identifiers: [2, 3]
        )
        accumulator.integrate(
            points: [SIMD3(4, 4, 4)],
            identifiers: [4]
        )

        let snapshot = accumulator.renderSnapshot(maximumCount: 10)

        XCTAssertEqual(snapshot.sourceCount, 3)
        XCTAssertEqual(snapshot.points.map(\.id), [2, 3, 4])
        XCTAssertEqual(snapshot.points.first?.position, SIMD3(2, 2, 2))
        XCTAssertFalse(snapshot.points.contains { $0.id == 1 })
    }

    func testMappingLandmarkAccumulatorIgnoresNonfiniteInput() {
        var accumulator = MappingLandmarkAccumulator(maximumRetainedLandmarks: 10)

        accumulator.integrate(
            points: [SIMD3(1, 2, 3), SIMD3(.infinity, 0, 0)],
            identifiers: [1, 2]
        )

        XCTAssertEqual(accumulator.renderSnapshot(maximumCount: 10).points.map(\.id), [1])
    }

    func testScanningNeverClaimsMapMatches() {
        let role = FeaturePointPresentation.role(
            for: 7,
            savedIdentifiers: [7],
            state: .scanning
        )

        XCTAssertEqual(role, .scanning)
    }

    func testSeekingNeverClaimsVerifiedGreenMatch() {
        let saved: Set<UInt64> = [7]

        XCTAssertEqual(
            FeaturePointPresentation.role(for: 7, savedIdentifiers: saved, state: .seekingMap),
            .seeking
        )
        XCTAssertEqual(
            FeaturePointPresentation.role(for: 8, savedIdentifiers: saved, state: .seekingMap),
            .seeking
        )
    }

    func testLocalizedFeaturesRemainGroundedInCurrentPointCloud() {
        let saved: Set<UInt64> = [7]

        XCTAssertEqual(
            FeaturePointPresentation.role(for: 7, savedIdentifiers: saved, state: .localized),
            .mapIdentityMatch
        )
        XCTAssertEqual(
            FeaturePointPresentation.role(for: 8, savedIdentifiers: saved, state: .localized),
            .localizedSupport
        )
    }

    func testSamplingIsBoundedUniqueAndDeterministic() {
        let first = FeaturePointPresentation.sampledIndices(count: 2_000, maximumCount: 240)
        let second = FeaturePointPresentation.sampledIndices(count: 2_000, maximumCount: 240)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 240)
        XCTAssertEqual(Set(first).count, first.count)
        XCTAssertTrue(first.allSatisfy { (0..<2_000).contains($0) })
    }

    func testSamplingRetainsPriorityMatches() {
        let priorities = [1, 17, 942, 1, -1, 5_000]
        let sampled = FeaturePointPresentation.sampledIndices(
            count: 1_000,
            maximumCount: 20,
            priorityIndices: priorities
        )

        XCTAssertTrue(sampled.contains(1))
        XCTAssertTrue(sampled.contains(17))
        XCTAssertTrue(sampled.contains(942))
        XCTAssertEqual(sampled.count, 20)
        XCTAssertEqual(Set(sampled).count, sampled.count)
    }

    func testSamplingReturnsAllIndicesWhenAlreadyBelowCap() {
        XCTAssertEqual(
            FeaturePointPresentation.sampledIndices(count: 4, maximumCount: 10),
            [0, 1, 2, 3]
        )
    }

    func testVisibleSelectionFillsBudgetFromVisibleCandidates() {
        let candidates = (0..<500).map { index in
            VisibleFeatureCandidate(
                id: UInt64(index),
                position: SIMD2(
                    Float(index % 25) / 24,
                    Float(index / 25) / 19
                )
            )
        }

        let selected = FeaturePointPresentation.selectVisibleCandidates(
            candidates,
            maximumCount: 240,
            priorityIdentifiers: []
        )

        XCTAssertEqual(selected.count, 240)
        XCTAssertEqual(Set(selected.map(\.id)).count, 240)
        XCTAssertTrue(selected.allSatisfy { candidate in
            (0...1).contains(candidate.position.x) && (0...1).contains(candidate.position.y)
        })
    }

    func testVisibleSelectionRetainsSavedPriorities() {
        let candidates = (0..<100).map { index in
            VisibleFeatureCandidate(
                id: UInt64(index),
                position: SIMD2(Float(index) / 99, 0.5)
            )
        }

        let selected = FeaturePointPresentation.selectVisibleCandidates(
            candidates,
            maximumCount: 12,
            priorityIdentifiers: [3, 71, 99]
        )

        XCTAssertTrue(selected.contains { $0.id == 3 })
        XCTAssertTrue(selected.contains { $0.id == 71 })
        XCTAssertTrue(selected.contains { $0.id == 99 })
        XCTAssertEqual(selected.count, 12)
    }

    func testVisibleSelectionDistributesAcrossViewport() {
        let candidates = [
            VisibleFeatureCandidate(id: 1, position: SIMD2(0.1, 0.1)),
            VisibleFeatureCandidate(id: 2, position: SIMD2(0.2, 0.2)),
            VisibleFeatureCandidate(id: 3, position: SIMD2(0.8, 0.1)),
            VisibleFeatureCandidate(id: 4, position: SIMD2(0.9, 0.2)),
            VisibleFeatureCandidate(id: 5, position: SIMD2(0.1, 0.8)),
            VisibleFeatureCandidate(id: 6, position: SIMD2(0.2, 0.9)),
            VisibleFeatureCandidate(id: 7, position: SIMD2(0.8, 0.8)),
            VisibleFeatureCandidate(id: 8, position: SIMD2(0.9, 0.9))
        ]

        let selected = FeaturePointPresentation.selectVisibleCandidates(
            candidates,
            maximumCount: 4,
            priorityIdentifiers: []
        )
        let occupiedQuadrants = Set(selected.map { candidate in
            (candidate.position.x >= 0.5 ? 1 : 0)
                + (candidate.position.y >= 0.5 ? 2 : 0)
        })

        XCTAssertEqual(selected.count, 4)
        XCTAssertEqual(occupiedQuadrants, [0, 1, 2, 3])
    }

    func testSeekingDoesNotPresentIdentifierOverlapAsVerifiedGreen() {
        XCTAssertEqual(
            FeaturePointPresentation.role(
                for: 7,
                savedIdentifiers: [7],
                state: .seekingMap
            ),
            .seeking
        )
    }

    func testSnapshotKeepsSourceVisibleAndDisplayedCountsDistinct() {
        let snapshot = FeaturePointSnapshot(
            points: [
                ScreenFeaturePoint(
                    id: 1,
                    position: SIMD2(0.5, 0.5),
                    role: .scanning
                )
            ],
            observedCount: 2_000,
            visibleCount: 713,
            rejectedBehindCameraCount: 806,
            rejectedOutsideViewportCount: 481,
            mapIdentityMatchCount: 0,
            timestamp: 10
        )

        XCTAssertEqual(snapshot.observedCount, 2_000)
        XCTAssertEqual(snapshot.visibleCount, 713)
        XCTAssertEqual(snapshot.displayedCount, 1)
        XCTAssertEqual(
            snapshot.rejectedBehindCameraCount + snapshot.rejectedOutsideViewportCount,
            snapshot.observedCount - snapshot.visibleCount
        )
    }

    func testMapRenderSnapshotRetainsExact3DLandmarksUnderLimit() {
        let landmarks = [
            SpatialLandmarkRecord(id: 1, position: Vector3Record(x: -1, y: 2, z: 3)),
            SpatialLandmarkRecord(id: 2, position: Vector3Record(x: 4, y: -5, z: 6))
        ]

        let renderSnapshot = SpatialMapRenderSnapshot.make(
            landmarks: landmarks,
            maximumCount: 10
        )

        XCTAssertEqual(renderSnapshot.sourceCount, 2)
        XCTAssertEqual(renderSnapshot.points.map(\.id), [1, 2])
        XCTAssertEqual(renderSnapshot.points[0].position, SIMD3(-1, 2, 3))
        XCTAssertEqual(renderSnapshot.points[1].position, SIMD3(4, -5, 6))
    }

    func testMapRenderLODRepresentsAllTopDownQuadrants() {
        let landmarks = [
            SpatialLandmarkRecord(id: 1, position: Vector3Record(x: -2, y: 0, z: -2)),
            SpatialLandmarkRecord(id: 2, position: Vector3Record(x: -1, y: 1, z: -1)),
            SpatialLandmarkRecord(id: 3, position: Vector3Record(x: 2, y: 2, z: -2)),
            SpatialLandmarkRecord(id: 4, position: Vector3Record(x: 1, y: 3, z: -1)),
            SpatialLandmarkRecord(id: 5, position: Vector3Record(x: -2, y: 4, z: 2)),
            SpatialLandmarkRecord(id: 6, position: Vector3Record(x: -1, y: 5, z: 1)),
            SpatialLandmarkRecord(id: 7, position: Vector3Record(x: 2, y: 6, z: 2)),
            SpatialLandmarkRecord(id: 8, position: Vector3Record(x: 1, y: 7, z: 1))
        ]

        let renderSnapshot = SpatialMapRenderSnapshot.make(
            landmarks: landmarks,
            maximumCount: 4
        )
        let quadrants = Set(renderSnapshot.points.map { point in
            (point.position.x >= 0 ? 1 : 0) + (point.position.z >= 0 ? 2 : 0)
        })

        XCTAssertEqual(renderSnapshot.points.count, 4)
        XCTAssertEqual(quadrants, [0, 1, 2, 3])
    }
}
