import Foundation

struct RelocalizationStateMachine {
    static let timeout: TimeInterval = 45
    static let mediumConfidenceDuration: TimeInterval = 0.5
    static let highConfidenceDuration: TimeInterval = 2.0

    enum TrackingInput: Equatable {
        case normal
        case limitedRelocalizing
        case limitedOther
        case unavailable
    }

    enum Reason: Equatable {
        case seekingMappedArea
        case awaitingMapOrigin
        case confirmingStableTracking
        case localized
        case relocalizing
        case trackingLimited
        case trackingUnavailable
        case timedOut
        case invalidElapsedTime

        var statusMessage: String {
            switch self {
            case .seekingMappedArea:
                return "Move slowly and look at textured areas you scanned before."
            case .awaitingMapOrigin:
                return "Tracking is available, but the saved map origin has not been restored yet."
            case .confirmingStableTracking:
                return "Map matched. Confirming stable tracking…"
            case .localized:
                return "Pose is expressed in the saved map frame."
            case .relocalizing:
                return "Matching the current view to the saved map."
            case .trackingLimited:
                return "Tracking is limited. Move slowly and point at textured surfaces."
            case .trackingUnavailable:
                return "Camera tracking is unavailable."
            case .timedOut:
                return "ARKit could not match this view within 45 seconds. Move to a distinctive mapped area or retry."
            case .invalidElapsedTime:
                return "Relocalization timing became invalid. Retry the saved map."
            }
        }
    }

    struct Output: Equatable {
        let phase: LocalizationPhase
        let confidence: ConfidenceBand
        let shouldPublishPose: Bool
        let reason: Reason
    }

    private(set) var sustainedNormalFrameCount = 0
    private(set) var sustainedNormalDuration: TimeInterval = 0
    private(set) var output = Output(
        phase: .relocalizing,
        confidence: .low,
        shouldPublishPose: false,
        reason: .seekingMappedArea
    )

    private var hasLocalized = false
    private var hasTerminalFailure = false
    private var normalTrackingStartedAt: TimeInterval?
    private var lastElapsedTime: TimeInterval?

    mutating func update(
        tracking: TrackingInput,
        originIsPresent: Bool,
        elapsedTime: TimeInterval
    ) -> Output {
        if hasTerminalFailure {
            return output
        }

        guard elapsedTime.isFinite,
              elapsedTime >= 0,
              lastElapsedTime.map({ elapsedTime >= $0 }) ?? true else {
            resetNormalStreak()
            hasTerminalFailure = true
            output = Output(
                phase: .failed,
                confidence: .unavailable,
                shouldPublishPose: false,
                reason: .invalidElapsedTime
            )
            return output
        }
        lastElapsedTime = elapsedTime

        let isValidMatch = tracking == .normal && originIsPresent
        if !hasLocalized, !isValidMatch, elapsedTime >= Self.timeout {
            sustainedNormalFrameCount = 0
            sustainedNormalDuration = 0
            hasTerminalFailure = true
            output = Output(
                phase: .failed,
                confidence: .unavailable,
                shouldPublishPose: false,
                reason: .timedOut
            )
            return output
        }

        switch tracking {
        case .normal where originIsPresent:
            hasLocalized = true
            if normalTrackingStartedAt == nil {
                normalTrackingStartedAt = elapsedTime
            }
            sustainedNormalFrameCount += 1
            sustainedNormalDuration = max(
                0,
                elapsedTime - (normalTrackingStartedAt ?? elapsedTime)
            )

            let confidence: ConfidenceBand
            if sustainedNormalDuration >= Self.highConfidenceDuration {
                confidence = .high
            } else if sustainedNormalDuration >= Self.mediumConfidenceDuration {
                confidence = .medium
            } else {
                confidence = .low
            }

            output = Output(
                phase: .tracking,
                confidence: confidence,
                shouldPublishPose: true,
                reason: sustainedNormalDuration < Self.mediumConfidenceDuration
                    ? .confirmingStableTracking
                    : .localized
            )

        case .normal:
            resetNormalStreak()
            output = Output(
                phase: .relocalizing,
                confidence: .low,
                shouldPublishPose: false,
                reason: .awaitingMapOrigin
            )

        case .limitedRelocalizing:
            resetNormalStreak()
            output = Output(
                phase: .relocalizing,
                confidence: .low,
                shouldPublishPose: false,
                reason: .relocalizing
            )

        case .limitedOther:
            resetNormalStreak()
            output = Output(
                phase: .limited,
                confidence: .low,
                shouldPublishPose: false,
                reason: .trackingLimited
            )

        case .unavailable:
            resetNormalStreak()
            output = Output(
                phase: .limited,
                confidence: .unavailable,
                shouldPublishPose: false,
                reason: .trackingUnavailable
            )
        }

        return output
    }

    mutating func reset() {
        resetNormalStreak()
        hasLocalized = false
        hasTerminalFailure = false
        lastElapsedTime = nil
        output = Output(
            phase: .relocalizing,
            confidence: .low,
            shouldPublishPose: false,
            reason: .seekingMappedArea
        )
    }

    private mutating func resetNormalStreak() {
        sustainedNormalFrameCount = 0
        sustainedNormalDuration = 0
        normalTrackingStartedAt = nil
    }
}
