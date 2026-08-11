import XCTest
@testable import HouseMapper

final class FeaturePointSnapshotTests: XCTestCase {
    func testScanningNeverClaimsMapMatches() {
        let role = FeaturePointPresentation.role(
            for: 7,
            savedIdentifiers: [7],
            state: .scanning
        )

        XCTAssertEqual(role, .scanning)
    }

    func testSeekingUsesGreenRoleOnlyForSavedIdentifierOverlap() {
        let saved: Set<UInt64> = [7]

        XCTAssertEqual(
            FeaturePointPresentation.role(for: 7, savedIdentifiers: saved, state: .seekingMap),
            .mapIdentityMatch
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
}
