import Foundation
import simd

struct CaptureDiagnosticsSnapshot: Equatable, Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let framesPerSecond: Double

    var description: String {
        "\(imageWidth)×\(imageHeight) • \(Int(framesPerSecond.rounded())) fps"
    }
}

struct CaptureDiagnosticsAccumulator: Sendable {
    let publicationInterval: TimeInterval

    private var windowStartTimestamp: TimeInterval?
    private var previousTimestamp: TimeInterval?
    private var intervalCount = 0

    init(publicationInterval: TimeInterval = 1) {
        self.publicationInterval = max(publicationInterval, 0.1)
    }

    mutating func record(
        timestamp: TimeInterval,
        imageWidth: Int,
        imageHeight: Int
    ) -> CaptureDiagnosticsSnapshot? {
        guard timestamp.isFinite, imageWidth > 0, imageHeight > 0 else { return nil }

        if let previousTimestamp, timestamp <= previousTimestamp {
            windowStartTimestamp = timestamp
            self.previousTimestamp = timestamp
            intervalCount = 0
            return nil
        }
        guard let windowStartTimestamp else {
            self.windowStartTimestamp = timestamp
            previousTimestamp = timestamp
            intervalCount = 0
            return nil
        }

        previousTimestamp = timestamp
        intervalCount += 1
        let elapsed = timestamp - windowStartTimestamp
        guard elapsed >= publicationInterval else { return nil }

        let snapshot = CaptureDiagnosticsSnapshot(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            framesPerSecond: Double(intervalCount) / elapsed
        )
        self.windowStartTimestamp = timestamp
        intervalCount = 0
        return snapshot
    }
}

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

struct VisibleFeatureCandidate: Identifiable, Equatable, Sendable {
    let id: UInt64
    /// Normalized camera viewport coordinates with origin at the upper-left.
    let position: SIMD2<Float>
}

struct SpatialMapRenderPoint: Identifiable, Equatable, Sendable {
    let id: UInt64
    let position: SIMD3<Float>
}

struct SpatialMapRenderBounds: Equatable, Sendable {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
}

struct SpatialMapRenderSnapshot: Equatable, Sendable {
    static let empty = SpatialMapRenderSnapshot(
        points: [],
        sourceCount: 0,
        bounds: SpatialMapRenderBounds(minimum: .zero, maximum: .zero)
    )

    let points: [SpatialMapRenderPoint]
    let sourceCount: Int
    let bounds: SpatialMapRenderBounds

    static func make(
        landmarks: [SpatialLandmarkRecord],
        maximumCount: Int
    ) -> SpatialMapRenderSnapshot {
        let sourcePoints = landmarks.map { landmark in
            SpatialMapRenderPoint(
                id: landmark.id,
                position: SIMD3(
                    landmark.position.x,
                    landmark.position.y,
                    landmark.position.z
                )
            )
        }
        return make(points: sourcePoints, maximumCount: maximumCount)
    }

    static func make(
        points sourcePoints: [SpatialMapRenderPoint],
        maximumCount: Int
    ) -> SpatialMapRenderSnapshot {
        guard let first = sourcePoints.first else { return .empty }

        var minimum = first.position
        var maximum = first.position
        for point in sourcePoints.dropFirst() {
            minimum = simd_min(minimum, point.position)
            maximum = simd_max(maximum, point.position)
        }
        let bounds = SpatialMapRenderBounds(minimum: minimum, maximum: maximum)
        guard maximumCount > 0 else {
            return SpatialMapRenderSnapshot(
                points: [],
                sourceCount: sourcePoints.count,
                bounds: bounds
            )
        }
        guard sourcePoints.count > maximumCount else {
            return SpatialMapRenderSnapshot(
                points: sourcePoints,
                sourceCount: sourcePoints.count,
                bounds: bounds
            )
        }

        let gridSide = max(1, Int(ceil(sqrt(Double(maximumCount)))))
        let spanX = max(maximum.x - minimum.x, Float.ulpOfOne)
        let spanZ = max(maximum.z - minimum.z, Float.ulpOfOne)
        var buckets = Array(repeating: [SpatialMapRenderPoint](), count: gridSide * gridSide)
        for point in sourcePoints {
            let normalizedX = (point.position.x - minimum.x) / spanX
            let normalizedZ = (point.position.z - minimum.z) / spanZ
            let x = min(gridSide - 1, max(0, Int(normalizedX * Float(gridSide))))
            let z = min(gridSide - 1, max(0, Int(normalizedZ * Float(gridSide))))
            buckets[z * gridSide + x].append(point)
        }

        var selected: [SpatialMapRenderPoint] = []
        selected.reserveCapacity(maximumCount)
        var offsets = Array(repeating: 0, count: buckets.count)
        while selected.count < maximumCount {
            var addedPoint = false
            for bucketIndex in buckets.indices where selected.count < maximumCount {
                let offset = offsets[bucketIndex]
                guard offset < buckets[bucketIndex].count else { continue }
                selected.append(buckets[bucketIndex][offset])
                offsets[bucketIndex] += 1
                addedPoint = true
            }
            if !addedPoint { break }
        }
        return SpatialMapRenderSnapshot(
            points: selected,
            sourceCount: sourcePoints.count,
            bounds: bounds
        )
    }
}

struct MappingLandmarkAccumulator: Sendable {
    let maximumRetainedLandmarks: Int

    private var positionsByIdentifier: [UInt64: SIMD3<Float>] = [:]
    private var lastSeenGeneration: [UInt64: Int] = [:]
    private var orderedIdentifiers: [UInt64] = []
    private var generation = 0

    init(maximumRetainedLandmarks: Int) {
        self.maximumRetainedLandmarks = max(1, maximumRetainedLandmarks)
    }

    mutating func integrate(points: [SIMD3<Float>], identifiers: [UInt64]) {
        generation &+= 1
        let sourceCount = min(points.count, identifiers.count)
        for index in 0..<sourceCount {
            let point = points[index]
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
            let identifier = identifiers[index]
            if positionsByIdentifier[identifier] == nil {
                orderedIdentifiers.append(identifier)
            }
            positionsByIdentifier[identifier] = point
            lastSeenGeneration[identifier] = generation
        }
        evictOldestIfNeeded()
    }

    func renderSnapshot(maximumCount: Int) -> SpatialMapRenderSnapshot {
        let points = orderedIdentifiers.compactMap { identifier -> SpatialMapRenderPoint? in
            guard let position = positionsByIdentifier[identifier] else { return nil }
            return SpatialMapRenderPoint(id: identifier, position: position)
        }
        return SpatialMapRenderSnapshot.make(points: points, maximumCount: maximumCount)
    }

    private mutating func evictOldestIfNeeded() {
        let excessCount = positionsByIdentifier.count - maximumRetainedLandmarks
        guard excessCount > 0 else { return }

        let evictedIdentifiers = positionsByIdentifier.keys.sorted { lhs, rhs in
            let lhsGeneration = lastSeenGeneration[lhs] ?? .min
            let rhsGeneration = lastSeenGeneration[rhs] ?? .min
            return lhsGeneration == rhsGeneration ? lhs < rhs : lhsGeneration < rhsGeneration
        }.prefix(excessCount)
        for identifier in evictedIdentifiers {
            positionsByIdentifier.removeValue(forKey: identifier)
            lastSeenGeneration.removeValue(forKey: identifier)
        }
        orderedIdentifiers.removeAll { positionsByIdentifier[$0] == nil }
    }
}

struct FeaturePointSnapshot: Equatable, Sendable {
    static let empty = FeaturePointSnapshot(
        points: [],
        observedCount: 0,
        visibleCount: 0,
        rejectedBehindCameraCount: 0,
        rejectedOutsideViewportCount: 0,
        mapIdentityMatchCount: 0,
        timestamp: 0
    )

    let points: [ScreenFeaturePoint]
    let observedCount: Int
    let visibleCount: Int
    let rejectedBehindCameraCount: Int
    let rejectedInvalidProjectionCount: Int
    let rejectedOutsideViewportCount: Int
    let mapIdentityMatchCount: Int
    let timestamp: TimeInterval

    var displayedCount: Int { points.count }

    init(
        points: [ScreenFeaturePoint],
        observedCount: Int,
        visibleCount: Int,
        rejectedBehindCameraCount: Int,
        rejectedInvalidProjectionCount: Int = 0,
        rejectedOutsideViewportCount: Int,
        mapIdentityMatchCount: Int,
        timestamp: TimeInterval
    ) {
        self.points = points
        self.observedCount = observedCount
        self.visibleCount = visibleCount
        self.rejectedBehindCameraCount = rejectedBehindCameraCount
        self.rejectedInvalidProjectionCount = rejectedInvalidProjectionCount
        self.rejectedOutsideViewportCount = rejectedOutsideViewportCount
        self.mapIdentityMatchCount = mapIdentityMatchCount
        self.timestamp = timestamp
    }
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
            return .seeking
        case .localized:
            return savedIdentifiers.contains(identifier) ? .mapIdentityMatch : .localizedSupport
        }
    }

    /// Selects a deterministic, spatially distributed subset after projection and
    /// visibility filtering. Priority identifiers are retained before the remaining
    /// viewport cells are sampled in round-robin order.
    static func selectVisibleCandidates(
        _ candidates: [VisibleFeatureCandidate],
        maximumCount: Int,
        priorityIdentifiers: Set<UInt64>
    ) -> [VisibleFeatureCandidate] {
        guard maximumCount > 0, !candidates.isEmpty else { return [] }

        var selected: [VisibleFeatureCandidate] = []
        selected.reserveCapacity(min(maximumCount, candidates.count))
        var selectedIdentifiers: Set<UInt64> = []
        selectedIdentifiers.reserveCapacity(min(maximumCount, candidates.count))

        for candidate in candidates where priorityIdentifiers.contains(candidate.id) {
            guard selectedIdentifiers.insert(candidate.id).inserted else { continue }
            selected.append(candidate)
            if selected.count == maximumCount { return selected }
        }

        let remainingCapacity = maximumCount - selected.count
        guard remainingCapacity > 0 else { return selected }
        let gridSide = max(1, Int(ceil(sqrt(Double(remainingCapacity)))))
        var buckets = Array(
            repeating: [VisibleFeatureCandidate](),
            count: gridSide * gridSide
        )

        for candidate in candidates where !selectedIdentifiers.contains(candidate.id) {
            let x = min(
                gridSide - 1,
                max(0, Int(candidate.position.x * Float(gridSide)))
            )
            let y = min(
                gridSide - 1,
                max(0, Int(candidate.position.y * Float(gridSide)))
            )
            buckets[y * gridSide + x].append(candidate)
        }

        var offsets = Array(repeating: 0, count: buckets.count)
        while selected.count < maximumCount {
            var addedCandidate = false
            for bucketIndex in buckets.indices where selected.count < maximumCount {
                let offset = offsets[bucketIndex]
                guard offset < buckets[bucketIndex].count else { continue }
                let candidate = buckets[bucketIndex][offset]
                offsets[bucketIndex] += 1
                guard selectedIdentifiers.insert(candidate.id).inserted else { continue }
                selected.append(candidate)
                addedCandidate = true
            }
            if !addedCandidate { break }
        }
        return selected
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
