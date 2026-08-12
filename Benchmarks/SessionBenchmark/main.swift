import Foundation

let startedAt = Date(timeIntervalSince1970: 1_000)
let frameIterations = 1_000_000
var frameAccumulator = SessionBenchmarkAccumulator(startedAt: startedAt)
let frameStart = DispatchTime.now().uptimeNanoseconds
for index in 0..<frameIterations {
    frameAccumulator.recordFrame(
        timestamp: Double(index) / 60,
        cameraWidth: 1_920,
        cameraHeight: 1_440,
        trackingCategory: index.isMultiple(of: 1_000) ? .limitedExcessiveMotion : .normal
    )
}
let frameElapsed = DispatchTime.now().uptimeNanoseconds - frameStart
let frameMeanNanoseconds = Double(frameElapsed) / Double(frameIterations)

let featureIterations = 100_000
let points = (0..<240).map { index in
    ScreenFeaturePoint(
        id: UInt64(index),
        position: SIMD2(Float(index % 20) / 20, Float(index / 20) / 12),
        role: .scanning
    )
}
let featureSnapshot = FeaturePointSnapshot(
    points: points,
    observedCount: 1_200,
    visibleCount: 530,
    rejectedBehindCameraCount: 190,
    rejectedInvalidProjectionCount: 2,
    rejectedOutsideViewportCount: 478,
    mapIdentityMatchCount: 0,
    timestamp: 10
)
var featureAccumulator = SessionBenchmarkAccumulator(startedAt: startedAt)
let featureStart = DispatchTime.now().uptimeNanoseconds
for _ in 0..<featureIterations {
    featureAccumulator.recordFeatureSnapshot(featureSnapshot)
}
let featureElapsed = DispatchTime.now().uptimeNanoseconds - featureStart
let featureMeanNanoseconds = Double(featureElapsed) / Double(featureIterations)
let featureReport = featureAccumulator.makeReport(
    mode: .mapping,
    completedAt: startedAt.addingTimeInterval(60),
    deviceModel: "benchmark-host",
    systemVersion: "host",
    appVersion: "1.0"
)
let featureChecksum = Int(featureReport.features?.meanObservedCount ?? 0)
    + (featureReport.features?.displayCappedSampleCount ?? 0)

let report = frameAccumulator.makeReport(
    mode: .mapping,
    completedAt: startedAt.addingTimeInterval(60),
    deviceModel: "benchmark-host",
    systemVersion: "host",
    appVersion: "1.0"
)
let encodeIterations = 10_000
let encodeStart = DispatchTime.now().uptimeNanoseconds
var encodedByteCount = 0
for _ in 0..<encodeIterations {
    encodedByteCount &+= try report.encodedJSON().count
}
let encodeElapsed = DispatchTime.now().uptimeNanoseconds - encodeStart
let encodeMeanMilliseconds = Double(encodeElapsed) / Double(encodeIterations) / 1_000_000

let formattedFrameMean = String(format: "%.2f", frameMeanNanoseconds)
let formattedFeatureMean = String(format: "%.2f", featureMeanNanoseconds)
let formattedJSONMean = String(format: "%.4f", encodeMeanMilliseconds)
print(
    "frame_records=\(frameIterations) mean_ns=\(formattedFrameMean) "
        + "feature_records=\(featureIterations) feature_mean_ns=\(formattedFeatureMean) "
        + "json_mean_ms=\(formattedJSONMean) "
        + "json_bytes=\(encodedByteCount / encodeIterations) "
        + "checksum=\(featureChecksum)"
)
