import Foundation

let sourceCount = 50_000
let displayCount = 12_000
let iterations = 100

let points = (0..<sourceCount).map { index in
    let angle = Float(index) * 0.017
    let ring = Float((index % 700) + 1) / 70
    return SpatialMapRenderPoint(
        id: UInt64(index),
        position: SIMD3(
            cos(angle) * ring,
            Float(index % 240) / 100 - 1.2,
            sin(angle) * ring
        )
    )
}

for _ in 0..<5 {
    _ = SpatialMapRenderSnapshot.make(points: points, maximumCount: displayCount)
}

var samples: [Double] = []
samples.reserveCapacity(iterations)
var checksum: UInt64 = 0
for _ in 0..<iterations {
    let start = ProcessInfo.processInfo.systemUptime
    let snapshot = SpatialMapRenderSnapshot.make(
        points: points,
        maximumCount: displayCount
    )
    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    checksum &+= snapshot.points.reduce(0) { $0 &+ $1.id }
}

let sorted = samples.sorted()
let median = sorted[sorted.count / 2]
let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
let maximum = sorted.last ?? 0
print("spatial-console-lod")
print("source_points=\(sourceCount)")
print("display_points=\(displayCount)")
print("iterations=\(iterations)")
print(String(format: "median_ms=%.3f", median))
print(String(format: "p95_ms=%.3f", p95))
print(String(format: "max_ms=%.3f", maximum))
print("checksum=\(checksum)")
