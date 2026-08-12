import Foundation
import simd

let frameCount = 216_000
var selector = MappingKeyframeSelector(
    minimumTranslationMeters: 0.45,
    minimumRotationRadians: 25 * .pi / 180,
    minimumTimeInterval: 0.75,
    minimumFeatureCount: 250,
    maximumKeyframeCount: 120
)
let start = DispatchTime.now().uptimeNanoseconds
var accepted = 0
for index in 0..<frameCount {
    let timestamp = Double(index) / 60
    let distance = Float(index) * 0.002
    var pose = matrix_identity_float4x4
    pose.columns.3 = SIMD4(distance, 0, -distance * 0.2, 1)
    if selector.reserveIfEligible(
        timestamp: timestamp,
        mapFromCamera: pose,
        tracking: index.isMultiple(of: 1_000) ? .limitedExcessiveMotion : .normal,
        featureCount: index.isMultiple(of: 700) ? 100 : 800
    ) {
        accepted += 1
        selector.commitMostRecentReservation()
    }
}
let elapsed = DispatchTime.now().uptimeNanoseconds - start
let meanNanoseconds = Double(elapsed) / Double(frameCount)

var captures: [PendingMappingKeyframe] = []
captures.reserveCapacity(120)
for index in 0..<120 {
    captures.append(
        PendingMappingKeyframe(
            id: UUID(),
            frameID: UInt64(index),
            capturedAt: Double(index),
            image: EncodedImageGeometry(width: 1_280, height: 960, orientation: .right, camera: .rearWide),
            intrinsics: Matrix3x3Record(values: [800, 0, 0, 0, 800, 0, 640, 480, 1]),
            mapFromCamera: Matrix4x4Record(matrix_identity_float4x4),
            tracking: .normal,
            sourceFeatureCount: 800,
            imageData: Data([1])
        )
    )
}
let manifestStart = DispatchTime.now().uptimeNanoseconds
let manifest = try MappingKeyframeManifest(mapID: UUID(), captures: captures)
let manifestData = try manifest.encodedJSON()
let manifestElapsed = DispatchTime.now().uptimeNanoseconds - manifestStart

let formattedSelectorMean = String(format: "%.2f", meanNanoseconds)
let formattedManifestMilliseconds = String(format: "%.3f", Double(manifestElapsed) / 1_000_000)
print(
    "frames=\(frameCount) accepted=\(accepted) selector_mean_ns=\(formattedSelectorMean) "
        + "manifest_keyframes=\(manifest.keyframes.count) manifest_bytes=\(manifestData.count) "
        + "manifest_build_encode_ms=\(formattedManifestMilliseconds)"
)
