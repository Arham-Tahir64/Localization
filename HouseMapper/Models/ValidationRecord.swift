import Foundation

struct ValidationRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let mapID: UUID
    let mapName: String
    let startedAt: Date
    let completedAt: Date
    let outcome: ValidationOutcome
    let startTrackingLabel: String
    let endTrackingLabel: String
    let startConfidenceLabel: String
    let endConfidenceLabel: String
    let finalPosition: ValidationPosition?
    let finalOrientation: ValidationOrientation?
    let notes: String?

    init(
        id: UUID = UUID(),
        mapID: UUID,
        mapName: String,
        startedAt: Date,
        completedAt: Date,
        outcome: ValidationOutcome,
        startTrackingLabel: String,
        endTrackingLabel: String,
        startConfidenceLabel: String,
        endConfidenceLabel: String,
        finalPosition: ValidationPosition? = nil,
        finalOrientation: ValidationOrientation? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.mapID = mapID
        self.mapName = mapName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.startTrackingLabel = startTrackingLabel
        self.endTrackingLabel = endTrackingLabel
        self.startConfidenceLabel = startConfidenceLabel
        self.endConfidenceLabel = endConfidenceLabel
        self.finalPosition = finalPosition
        self.finalOrientation = finalOrientation
        self.notes = notes
    }

    var duration: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }
}

enum ValidationOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case timeout
    case cancelled
    case sessionFailure

    var title: String {
        switch self {
        case .success: return "Success"
        case .timeout: return "Timed out"
        case .cancelled: return "Cancelled"
        case .sessionFailure: return "Session failure"
        }
    }

    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .cancelled: return "xmark.circle"
        case .sessionFailure: return "exclamationmark.triangle.fill"
        }
    }
}

struct ValidationPosition: Codable, Hashable, Sendable {
    let x: Float
    let y: Float
    let z: Float
}

struct ValidationOrientation: Codable, Hashable, Sendable {
    let pitch: Float
    let yaw: Float
    let roll: Float
}
