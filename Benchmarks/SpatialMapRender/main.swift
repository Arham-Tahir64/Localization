import Foundation

private let cases = [
    (count: 10_000, iterations: 200),
    (count: 100_000, iterations: 40),
    (count: 1_000_000, iterations: 4)
]

for benchmarkCase in cases {
    var points: [SpatialMapRenderPoint] = []
    points.reserveCapacity(benchmarkCase.count)
    for index in 0..<benchmarkCase.count {
        let x = Float((index &* 37) % 20_003) * 0.002 - 20
        let y = Float((index &* 17) % 401) * 0.007 - 1
        let z = Float((index &* 101) % 19_997) * 0.002 - 20
        points.append(
            SpatialMapRenderPoint(
                id: UInt64(index),
                position: SIMD3(x, y, z)
            )
        )
    }

    let warmup = SpatialMapRenderSnapshot.make(points: points, maximumCount: 4_000)
    precondition(warmup.sourceCount == benchmarkCase.count)
    precondition(warmup.points.count == min(benchmarkCase.count, 4_000))

    let start = DispatchTime.now().uptimeNanoseconds
    var checksum = 0
    for _ in 0..<benchmarkCase.iterations {
        let snapshot = SpatialMapRenderSnapshot.make(points: points, maximumCount: 4_000)
        checksum &+= snapshot.points.count
        checksum &+= Int(snapshot.bounds.maximum.x - snapshot.bounds.minimum.x)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let meanMilliseconds = Double(elapsed) / Double(benchmarkCase.iterations) / 1_000_000
    let formattedMean = String(format: "%.4f", meanMilliseconds)
    print(
        "landmarks=\(benchmarkCase.count) iterations=\(benchmarkCase.iterations) "
            + "render_points=\(warmup.points.count) "
            + "mean_ms=\(formattedMean) "
            + "checksum=\(checksum)"
    )
}

let frameCount = 120
let pointsPerFrame = 1_000
var inputFrames: [(points: [SIMD3<Float>], identifiers: [UInt64])] = []
inputFrames.reserveCapacity(frameCount)
for frame in 0..<frameCount {
    var points: [SIMD3<Float>] = []
    var identifiers: [UInt64] = []
    points.reserveCapacity(pointsPerFrame)
    identifiers.reserveCapacity(pointsPerFrame)
    for index in 0..<pointsPerFrame {
        let identifier = frame * 500 + index
        identifiers.append(UInt64(identifier))
        points.append(
            SIMD3(
                Float(identifier % 1_003) * 0.02,
                Float(identifier % 101) * 0.01,
                -Float(identifier / 1_003) * 0.1
            )
        )
    }
    inputFrames.append((points, identifiers))
}

var accumulator = MappingLandmarkAccumulator(maximumRetainedLandmarks: 50_000)
let accumulationStart = DispatchTime.now().uptimeNanoseconds
var accumulationChecksum = 0
for frame in inputFrames {
    accumulator.integrate(points: frame.points, identifiers: frame.identifiers)
    accumulationChecksum &+= accumulator.renderSnapshot(maximumCount: 4_000).sourceCount
}
let accumulationElapsed = DispatchTime.now().uptimeNanoseconds - accumulationStart
let accumulationMean = Double(accumulationElapsed) / Double(frameCount) / 1_000_000
let finalAccumulatedSnapshot = accumulator.renderSnapshot(maximumCount: 4_000)
let formattedAccumulationMean = String(format: "%.4f", accumulationMean)
print(
    "accumulator_frames=\(frameCount) points_per_frame=\(pointsPerFrame) "
        + "retained=\(finalAccumulatedSnapshot.sourceCount) "
        + "mean_integrate_render_ms=\(formattedAccumulationMean) "
        + "checksum=\(accumulationChecksum)"
)
