import XCTest
import simd
@testable import HouseMapper

final class RelocalizationStressTests: XCTestCase {
    func testAnchorArrivalOrderKeepsPoseSuppressedUntilBothConditionsHold() {
        var machine = RelocalizationStateMachine()

        for frame in 0..<30 {
            let output = machine.update(
                tracking: .normal,
                originIsPresent: false,
                elapsedTime: Double(frame) / 60
            )
            XCTAssertFalse(output.shouldPublishPose)
            XCTAssertEqual(output.reason, .awaitingMapOrigin)
            XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
        }

        let originArrived = machine.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 0.5
        )
        XCTAssertTrue(originArrived.shouldPublishPose)
        XCTAssertEqual(originArrived.confidence, .low)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 1)

        let originLost = machine.update(
            tracking: .normal,
            originIsPresent: false,
            elapsedTime: 0.6
        )
        XCTAssertFalse(originLost.shouldPublishPose)
        XCTAssertEqual(machine.sustainedNormalFrameCount, 0)
    }

    func testValidMatchWinsAtDeadlineBoundary() {
        var justBeforeDeadline = RelocalizationStateMachine()
        let before = justBeforeDeadline.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: 44.999_999
        )
        XCTAssertTrue(before.shouldPublishPose)
        XCTAssertEqual(before.phase, .tracking)

        var atDeadline = RelocalizationStateMachine()
        let deadline = atDeadline.update(
            tracking: .normal,
            originIsPresent: true,
            elapsedTime: RelocalizationStateMachine.timeout
        )
        XCTAssertTrue(deadline.shouldPublishPose)
        XCTAssertEqual(deadline.phase, .tracking)
    }

    func testNonFiniteAndNegativeElapsedTimeFailClosed() {
        for elapsed in [-1.0, -.leastNonzeroMagnitude, .nan, -.infinity] {
            var machine = RelocalizationStateMachine()
            let output = machine.update(
                tracking: .limitedRelocalizing,
                originIsPresent: false,
                elapsedTime: elapsed
            )
            XCTAssertEqual(output.phase, .failed, "elapsed=\(elapsed)")
            XCTAssertEqual(output.reason, .invalidElapsedTime, "elapsed=\(elapsed)")
        }
    }

    func testFixedSeedAdversarialSequencesOnlyPublishForNormalTrackingWithOrigin() {
        var machine = RelocalizationStateMachine()
        var generator = LCG(seed: 0x5EED_C0DE)
        var expectedStreak = 0
        var publishedFrames = 0

        for frame in 0..<10_000 {
            let random = generator.next()
            let tracking = trackingInput(for: random % 4)
            let originIsPresent = (random & 0b100) != 0
            let output = machine.update(
                tracking: tracking,
                originIsPresent: originIsPresent,
                elapsedTime: Double(frame % 44_000) / 1_000
            )

            if tracking == .normal && originIsPresent {
                expectedStreak += 1
                XCTAssertTrue(output.shouldPublishPose)
                publishedFrames += 1
            } else {
                expectedStreak = 0
                XCTAssertFalse(output.shouldPublishPose)
            }

            XCTAssertEqual(machine.sustainedNormalFrameCount, expectedStreak)
            XCTAssertEqual(
                output.confidence,
                tracking == .unavailable
                    ? .unavailable
                    : confidence(forDuration: Double(max(0, expectedStreak - 1)) / 1_000)
            )
        }

        XCTAssertGreaterThan(publishedFrames, 0)
    }

    func testConfidenceDurationIsStableAcrossInputFrameRates() {
        let thirtyFPSLatency = secondsToMediumConfidence(frameRate: 30)
        let sixtyFPSLatency = secondsToMediumConfidence(frameRate: 60)

        XCTAssertEqual(thirtyFPSLatency, 0.5, accuracy: 1.0 / 30.0)
        XCTAssertEqual(sixtyFPSLatency, 0.5, accuracy: 1.0 / 60.0)
        XCTAssertEqual(thirtyFPSLatency, sixtyFPSLatency, accuracy: 1.0 / 30.0)
    }

    func testDeterministicRigidTransformStressPreservesCompositionAndInverses() {
        var generator = LCG(seed: 0xC001_D00D)
        var largestError: Float = 0

        for _ in 0..<500 {
            let mapFromWorld = transform(generator: &generator)
            let worldFromCamera = transform(generator: &generator)
            let globalMapFromCamera = simd_mul(mapFromWorld, worldFromCamera)

            let recoveredMapFromWorld = CoordinateFrames.mapFromWorld(
                globalMapFromCamera: globalMapFromCamera,
                worldFromCameraAtMatch: worldFromCamera
            )
            let mapFromCamera = CoordinateFrames.mapFromCamera(
                mapFromWorld: mapFromWorld,
                worldFromCamera: worldFromCamera
            )
            let cameraFromWorld = CoordinateFrames.worldFromCamera(worldFromCamera)

            largestError = max(
                largestError,
                matrixError(recoveredMapFromWorld, mapFromWorld),
                matrixError(mapFromCamera, globalMapFromCamera),
                matrixError(simd_mul(worldFromCamera, cameraFromWorld), matrix_identity_float4x4)
            )
        }

        XCTAssertLessThanOrEqual(largestError, 0.000_1)
    }

    func testStateMachineUpdatePerformanceFixedScenario() {
        measure {
            var machine = RelocalizationStateMachine()
            for frame in 0..<100_000 {
                _ = machine.update(
                    tracking: frame % 17 == 0 ? .limitedRelocalizing : .normal,
                    originIsPresent: frame % 17 != 1,
                    elapsedTime: Double(frame) / 1_000
                )
            }
        }
    }

    private func secondsToMediumConfidence(frameRate: Double) -> Double {
        var machine = RelocalizationStateMachine()
        var elapsedTime = 0.0
        var firstValidElapsedTime: Double?

        while machine.output.confidence != .medium {
            elapsedTime += 1 / frameRate
            if firstValidElapsedTime == nil { firstValidElapsedTime = elapsedTime }
            _ = machine.update(
                tracking: .normal,
                originIsPresent: true,
                elapsedTime: elapsedTime
            )
        }

        return elapsedTime - (firstValidElapsedTime ?? 0)
    }

    private func trackingInput(for value: UInt64) -> RelocalizationStateMachine.TrackingInput {
        switch value {
        case 0: return .normal
        case 1: return .limitedRelocalizing
        case 2: return .limitedOther
        default: return .unavailable
        }
    }

    private func confidence(forDuration duration: TimeInterval) -> ConfidenceBand {
        if duration >= RelocalizationStateMachine.highConfidenceDuration { return .high }
        if duration >= RelocalizationStateMachine.mediumConfidenceDuration { return .medium }
        return .low
    }

    private func transform(generator: inout LCG) -> simd_float4x4 {
        let translation = SIMD3<Float>(
            generator.nextFloat(in: -25...25),
            generator.nextFloat(in: -2...4),
            generator.nextFloat(in: -25...25)
        )
        let yaw = generator.nextFloat(in: -.pi ... .pi)
        let pitch = generator.nextFloat(in: -.pi / 3 ... .pi / 3)
        let rotation = simd_mul(
            simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)),
            simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        )
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
        return matrix
    }

    private func matrixError(_ left: simd_float4x4, _ right: simd_float4x4) -> Float {
        var maximum: Float = 0
        for column in 0..<4 {
            for row in 0..<4 {
                maximum = max(maximum, abs(left[column][row] - right[column][row]))
            }
        }
        return maximum
    }
}

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        let unit = Float(next() >> 40) / Float(1 << 24)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
