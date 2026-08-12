import Foundation

private let sizes = [1_000, 5_000, 20_000, 100_000]

for candidateCount in sizes {
    var candidates: [VisibleFeatureCandidate] = []
    candidates.reserveCapacity(candidateCount)
    for index in 0..<candidateCount {
        let x = Float((index &* 37) % 997) / 996
        let y = Float((index &* 101) % 991) / 990
        candidates.append(
            VisibleFeatureCandidate(
                id: UInt64(index),
                position: SIMD2(x, y)
            )
        )
    }

    let priorities = Set(candidates.prefix(24).map(\.id))
    let iterations: Int
    switch candidateCount {
    case ..<5_000: iterations = 500
    case ..<20_000: iterations = 200
    case ..<100_000: iterations = 80
    default: iterations = 20
    }

    _ = FeaturePointPresentation.selectVisibleCandidates(
        candidates,
        maximumCount: 240,
        priorityIdentifiers: priorities
    )

    let start = DispatchTime.now().uptimeNanoseconds
    var checksum = 0
    for _ in 0..<iterations {
        checksum += FeaturePointPresentation.selectVisibleCandidates(
            candidates,
            maximumCount: 240,
            priorityIdentifiers: priorities
        ).count
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let meanMilliseconds = Double(elapsed) / Double(iterations) / 1_000_000
    let formattedMean = String(format: "%.4f", meanMilliseconds)
    print(
        "candidates=\(candidateCount) iterations=\(iterations) "
            + "mean_ms=\(formattedMean) checksum=\(checksum)"
    )
}
