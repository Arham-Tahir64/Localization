import Foundation

private let sizes = [10_000, 100_000]

for landmarkCount in sizes {
    let mapID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var landmarks: [SpatialLandmarkRecord] = []
    landmarks.reserveCapacity(landmarkCount)
    for index in 0..<landmarkCount {
        let position = Vector3Record(
            x: Float(index % 1_000) * 0.03,
            y: Float((index / 1_000) % 20) * 0.05,
            z: Float(index / 20_000) * -0.25
        )
        landmarks.append(
            SpatialLandmarkRecord(
                id: UInt64(index),
                position: position
            )
        )
    }
    let snapshot = try SpatialMapSnapshot(mapID: mapID, landmarks: landmarks)

    let encodeStart = DispatchTime.now().uptimeNanoseconds
    let encoded = try SpatialMapSnapshotCodec.encode(snapshot)
    let encodeMilliseconds = Double(
        DispatchTime.now().uptimeNanoseconds - encodeStart
    ) / 1_000_000

    let decodeStart = DispatchTime.now().uptimeNanoseconds
    let decoded = try SpatialMapSnapshotCodec.decode(encoded, expectedMapID: mapID)
    let decodeMilliseconds = Double(
        DispatchTime.now().uptimeNanoseconds - decodeStart
    ) / 1_000_000

    precondition(decoded == snapshot)
    print(
        "landmarks=\(landmarkCount) bytes=\(encoded.count) "
            + "encode_ms=\(String(format: "%.3f", encodeMilliseconds)) "
            + "decode_ms=\(String(format: "%.3f", decodeMilliseconds))"
    )
}
