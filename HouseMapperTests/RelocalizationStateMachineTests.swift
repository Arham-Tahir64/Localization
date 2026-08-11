import XCTest
@testable import HouseMapper

final class RelocalizationStateMachineTests: XCTestCase {
    func testInitialStateSeeksMappedAreaWithoutPublishingPose() {
        let machine = RelocalizationStateMachine()

        XCTAssertEqual(machine.output.phase, .relocalizing)
        XCTAssertEqual(machine.output.confidence, .low)
        XCTAssertFalse(machine.output.shouldPublishPose)
        XCTAssertEqual(machine.output.reason, .seekingMappedArea)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
    }

    func testNormalTrackingRequiresRestoredOriginBeforePublishingPose() {
        var machine = RelocalizationStateMachine()

        let output = machine.update(
            tracking: .normal,
            originIsPresent: false,
            elapsedTime: 1
        )

        XCTAssertEqual(output.phase, .relocalizing)
        XCTAssertEqual(output.confidence, .low)
        XCTAssertFalse(output.shouldPublishPose)
        XCTAssertEqual(output.reason, .awaitingMapOrigin)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
    }

    func testNormalTrackingWithOriginPublishesLowConfidencePoseImmediately() {
        var machine = RelocalizationStateMachine()

        let output = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 1
        )

        XCTAssertEqual(output.phase, .tracking)
        XCTAssertEqual(output.confidence, .low)
        XCTAssertTrue(output.shouldPublishPose)
        XCTAssertEqual(output.reason, .confirmingStableTracking)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 1)
    }

    func testConfidenceChangesAtExactSustainedNormalThresholds() {
        var machine = RelocalizationStateMachine()
        var output = machine.output

        for frame in 1...14 {
            output = machine.update(
                tracking: .normal,
                originIsPresent: true,
                elapsedTime: TimeInterval(frame)
            )
        }
        XCTAssertEqual(output.confidence, .low)
        XCTAssertEqual(output.reason, .confirmingStableTracking)

        output = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 15
        )
        XCTAssertEqual(output.confidence, .medium)
        XCTAssertEqual(output.reason, .localized)

        for frame in 16...59 {
            output = machine.update(
                tracking: .normal,
                originIsPresent: true,
                elapsedTime: TimeInterval(frame)
            )
        }
        XCTAssertEqual(output.confidence, .medium)

        output = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 60
        )
        XCTAssertEqual(output.confidence, .high)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 60)
    }

    func testLimitedRelocalizingUsesRelocalizationPhaseAndSuppressesPose() {
        var machine = localizedMachine()

        let output = machine.update(
            tracking: .limitedRelocalizing,
            originIsPresent: true,
            elapsedTime: 2
        )

        XCTAssertEqual(output.phase, .relocalizing)
        XCTAssertEqual(output.confidence, .low)
        XCTAssertFalse(output.shouldPublishPose)
        XCTAssertEqual(output.reason, .relocalizing)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
    }

    func testOtherLimitedReasonUsesLimitedPhaseAndSuppressesPose() {
        var machine = localizedMachine()

        let output = machine.update(
            tracking: .limitedOther,
            originIsPresent: true,
            elapsedTime: 2
        )

        XCTAssertEqual(output.phase, .limited)
        XCTAssertEqual(output.confidence, .low)
        XCTAssertFalse(output.shouldPublishPose)
        XCTAssertEqual(output.reason, .trackingLimited)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
    }

    func testUnavailableTrackingUsesUnavailableConfidenceAndSuppressesPose() {
        var machine = localizedMachine()

        let output = machine.update(
            tracking: .unavailable,
            originIsPresent: true,
            elapsedTime: 2
        )

        XCTAssertEqual(output.phase, .limited)
        XCTAssertEqual(output.confidence, .unavailable)
        XCTAssertFalse(output.shouldPublishPose)
        XCTAssertEqual(output.reason, .trackingUnavailable)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
    }

    func testTrackingLossResetsConfidenceAndRecoveryStartsNewStreak() {
        var machine = RelocalizationStateMachine()
        for frame in 1...20 {
            _ = machine.update(
                tracking: .normal,
                originIsPresent: true,
                elapsedTime: TimeInterval(frame)
            )
        }
        XCTAssertEqual(machine.output.confidence, .medium)

        _ = machine.update(
            tracking: .limitedOther,
            originIsPresent: true,
            elapsedTime: 21
        )
        let recovered = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 22
        )

        XCTAssertEqual(machine.sustainedNormalFrameCount, 1)
        XCTAssertEqual(recovered.phase, .tracking)
        XCTAssertEqual(recovered.confidence, .low)
        XCTAssertTrue(recovered.shouldPublishPose)
        XCTAssertEqual(recovered.reason, .confirmingStableTracking)
    }

    func testOriginLossSuppressesPoseAndRecoveryStartsNewStreak() {
        var machine = localizedMachine()

        let lost = machine.update(
            tracking: .normal,
            originIsPresent: false,
            elapsedTime: 2
        )
        let recovered = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 3
        )

        XCTAssertFalse(lost.shouldPublishPose)
        XCTAssertEqual(lost.reason, .awaitingMapOrigin)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 1)
        XCTAssertTrue(recovered.shouldPublishPose)
        XCTAssertEqual(recovered.confidence, .low)
    }

    func testTimeoutOccursAtFortyFiveSecondsWhenNeverLocalized() {
        var machine = RelocalizationStateMachine()

        let beforeDeadline = machine.update(
            tracking: .limitedRelocalizing,
            originIsPresent: false,
            elapsedTime: 44.999
        )
        let atDeadline = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 45
        )

        XCTAssertEqual(beforeDeadline.phase, .relocalizing)
        XCTAssertEqual(atDeadline.phase, .failed)
        XCTAssertEqual(atDeadline.confidence, .unavailable)
        XCTAssertFalse(atDeadline.shouldPublishPose)
        XCTAssertEqual(atDeadline.reason, .timedOut)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
    }

    func testTimeoutFailureIsLatchedUntilReset() {
        var machine = RelocalizationStateMachine()
        let timedOut = machine.update(
            tracking: .unavailable,
            originIsPresent: false,
            elapsedTime: 45
        )

        let afterGoodInput = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 46
        )

        XCTAssertEqual(afterGoodInput, timedOut)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)

        machine.reset()
        let afterReset = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 0
        )

        XCTAssertEqual(afterReset.phase, .tracking)
        XCTAssertEqual(afterReset.confidence, .low)
        XCTAssertTrue(afterReset.shouldPublishPose)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 1)
    }

    func testElapsedDeadlineDoesNotFailAPreviouslyLocalizedSession() {
        var machine = localizedMachine()

        let lossAfterDeadline = machine.update(
            tracking: .limitedRelocalizing,
            originIsPresent: true,
            elapsedTime: 60
        )
        let recoveryAfterDeadline = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 61
        )

        XCTAssertEqual(lossAfterDeadline.phase, .relocalizing)
        XCTAssertEqual(lossAfterDeadline.reason, .relocalizing)
        XCTAssertEqual(recoveryAfterDeadline.phase, .tracking)
        XCTAssertTrue(recoveryAfterDeadline.shouldPublishPose)
    }

    func testReasonsProvideControllerReadyStatusMessages() {
        XCTAssertFalse(RelocalizationStateMachine.Reason.seekingMappedArea.statusMessage.isEmpty)
        XCTAssertTrue(RelocalizationStateMachine.Reason.timedOut.statusMessage.contains("45"))
    }

    private func localizedMachine() -> RelocalizationStateMachine {
        var machine = RelocalizationStateMachine()
        _ = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 1
        )
        return machine
    }
}
