import Foundation
import simd

enum FeatureOverlayState: Equatable, Sendable {
    case scanning
    case seekingMap
    case localized
}

enum FeaturePointRole: Equatable, Sendable {
    case scanning
    case seeking
    case mapIdentityMatch
    case localizedSupport
}

struct ScreenFeaturePoint: Identifiable, Equatable, Sendable {
    let id: UInt64
    /// Normalized camera viewport coordinates with origin at the upper-left.
    let position: SIMD2<Float>
    let role: FeaturePointRole
}

struct FeaturePointSnapshot: Equatable, Sendable {
    static let empty = FeaturePointSnapshot(
        points: [],
        observedCount: 0,
        mapIdentityMatchCount: 0,
        timestamp: 0
    )

    let points: [ScreenFeaturePoint]
    let observedCount: Int
    let mapIdentityMatchCount: Int
    let timestamp: TimeInterval
}

enum FeaturePointPresentation {
    static func role(
        for identifier: UInt64,
        savedIdentifiers: Set<UInt64>,
        state: FeatureOverlayState
    ) -> FeaturePointRole {
        switch state {
        case .scanning:
            return .scanning
        case .seekingMap:
            return savedIdentifiers.contains(identifier) ? .mapIdentityMatch : .seeking
        case .localized:
            return savedIdentifiers.contains(identifier) ? .mapIdentityMatch : .localizedSupport
        }
    }

    /// Evenly samples the source while retaining as many priority indices as possible.
    static func sampledIndices(
        count: Int,
        maximumCount: Int,
        priorityIndices: [Int] = []
    ) -> [Int] {
        guard count > 0, maximumCount > 0 else { return [] }
        if count <= maximumCount { return Array(0..<count) }

        var selected: [Int] = []
        selected.reserveCapacity(maximumCount)
        var selectedSet: Set<Int> = []

        for index in priorityIndices where index >= 0 && index < count {
            guard selectedSet.insert(index).inserted else { continue }
            selected.append(index)
            if selected.count == maximumCount { return selected.sorted() }
        }

        let remainingCapacity = maximumCount - selected.count
        guard remainingCapacity > 0 else { return selected.sorted() }
        let step = Double(count) / Double(remainingCapacity)
        var cursor = step / 2
        while selected.count < maximumCount, Int(cursor) < count {
            let index = Int(cursor)
            if selectedSet.insert(index).inserted {
                selected.append(index)
            }
            cursor += step
        }

        if selected.count < maximumCount {
            for index in 0..<count where selectedSet.insert(index).inserted {
                selected.append(index)
                if selected.count == maximumCount { break }
            }
        }
        return selected.sorted()
    }
}
