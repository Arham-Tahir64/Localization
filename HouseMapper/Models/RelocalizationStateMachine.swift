import Foundation

struct RelocalizationStateMachine {
    static let timeout: TimeInterval = 45
    static let mediumConfidenceFrameCount = 15
    static let highConfidenceFrameCount = 60

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
    private(set) var output = Output(
        phase: .relocalizing,
        confidence: .low,
        shouldPublishPose: false,
        reason: .seekingMappedArea
    )

    private var hasLocalized = false
    private var hasTimedOut = false

    mutating func update(
        tracking: TrackingInput,
        originIsPresent: Bool,
        elapsedTime: TimeInterval
    ) -> Output {
        if hasTimedOut {
            return output
        }

        if !hasLocalized, elapsedTime >= Self.timeout {
            sustainedNormalFrameCount = 0
            hasTimedOut = true
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
            sustainedNormalFrameCount += 1

            let confidence: ConfidenceBand
            if sustainedNormalFrameCount >= Self.highConfidenceFrameCount {
                confidence = .high
            } else if sustainedNormalFrameCount >= Self.mediumConfidenceFrameCount {
                confidence = .medium
            } else {
                confidence = .low
            }

            output = Output(
                phase: .tracking,
                confidence: confidence,
                shouldPublishPose: true,
                reason: sustainedNormalFrameCount < Self.mediumConfidenceFrameCount
                    ? .confirmingStableTracking
                    : .localized
            )

        case .normal:
            sustainedNormalFrameCount = 0
            output = Output(
                phase: .relocalizing,
                confidence: .low,
                shouldPublishPose: false,
                reason: .awaitingMapOrigin
            )

        case .limitedRelocalizing:
            sustainedNormalFrameCount = 0
            output = Output(
                phase: .relocalizing,
                confidence: .low,
                shouldPublishPose: false,
                reason: .relocalizing
            )

        case .limitedOther:
            sustainedNormalFrameCount = 0
            output = Output(
                phase: .limited,
                confidence: .low,
                shouldPublishPose: false,
                reason: .trackingLimited
            )

        case .unavailable:
            sustainedNormalFrameCount = 0
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
        sustainedNormalFrameCount = 0
        hasLocalized = false
        hasTimedOut = false
        output = Output(
            phase: .relocalizing,
            confidence: .low,
            shouldPublishPose: false,
            reason: .seekingMappedArea
        )
    }
}
