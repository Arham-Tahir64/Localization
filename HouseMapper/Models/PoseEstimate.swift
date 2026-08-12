import Foundation
import simd

enum ExperienceMode: Equatable {
    case mapping
    case relocalization(MapPackage)

    var title: String {
        switch self {
        case .mapping:
            return "Create Map"
        case .relocalization(let package):
            return package.metadata.name
        }
    }

    var benchmarkMode: BenchmarkSessionMode {
        switch self {
        case .mapping: return .mapping
        case .relocalization: return .relocalization
        }
    }
}

enum LocalizationPhase: String {
    case mapping = "Mapping"
    case loading = "Loading map"
    case relocalizing = "Relocalizing"
    case tracking = "Tracking in map"
    case limited = "Tracking limited"
    case interrupted = "Interrupted"
    case failed = "Not localized"
    case unsupported = "Unsupported"
}

enum ConfidenceBand: String {
    case unavailable = "Unavailable"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var symbolName: String {
        switch self {
        case .unavailable: return "questionmark.circle"
        case .low: return "exclamationmark.triangle"
        case .medium: return "circle.lefthalf.filled"
        case .high: return "checkmark.circle.fill"
        }
    }
}

struct CameraPose: Equatable {
    let mapFromCamera: simd_float4x4
    let eulerAngles: SIMD3<Float>
    let timestamp: TimeInterval

    var position: SIMD3<Float> {
        SIMD3(
            mapFromCamera.columns.3.x,
            mapFromCamera.columns.3.y,
            mapFromCamera.columns.3.z
        )
    }
}

struct GridKey: Hashable {
    let x: Int
    let z: Int
}
