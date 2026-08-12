import Foundation
import simd

@main
struct ConnectedLocalizationBenchmark {
    static func main() throws {
        let mapID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let versionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let reference = ServerMapReference(mapID: mapID, versionID: versionID)
        let manifest = ServerMapManifest(
            map: reference,
            createdAt: Date(timeIntervalSince1970: 1_000),
            queryEndpoint: "https://mapper.example/v1/localize",
            models: ServerModelIdentity(
                reconstruction: "COLMAP-3.13",
                retrieval: "NetVLAD",
                localFeatures: "SuperPoint",
                matcher: "LightGlue"
            ),
            query: ServerQueryConfiguration(
                maximumImageWidth: 1_280,
                jpegQuality: 0.8,
                minimumQueryInterval: 0.75,
                requestTimeout: 8
            )
        )
        let observation = makeObservation(reference: reference, frameID: 1)
        let request = try ServerLocalizationRequest(
            observation: observation,
            jpegImage: syntheticJPEG(byteCount: 250_000)
        )
        let response = makeResponse(for: observation)

        let manifestData = try manifest.encodedJSON()
        let requestData = try request.encodedJSON()
        let responseData = try JSONEncoder().encode(response)

        let manifestResult = try measure(iterations: 20_000) {
            _ = try ServerMapManifest.decode(manifestData, expectedMapID: mapID)
        }
        let responseResult = try measure(iterations: 50_000) {
            let decoded = try JSONDecoder().decode(
                ServerLocalizationResponse.self,
                from: responseData
            )
            try request.validate(response: decoded)
        }
        let poseResult = try measure(iterations: 100_000) {
            _ = try response.result.mapFromWorld(for: observation)
        }
        let requestResult = try measure(iterations: 500) {
            _ = try request.encodedJSON()
        }

        let output: [String: Any] = [
            "environment": [
                "kind": "host-synthetic",
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "note": "This is contract overhead, not localization accuracy or iPhone latency."
            ],
            "payloadBytes": [
                "manifest": manifestData.count,
                "requestWith250KBJPEG": requestData.count,
                "responseWith64Inliers": responseData.count
            ],
            "benchmarks": [
                "manifestDecodeValidate": manifestResult.dictionary,
                "responseDecodeValidate": responseResult.dictionary,
                "mapWorldPoseBridge": poseResult.dictionary,
                "requestJSONEncode": requestResult.dictionary
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private static func measure(
        iterations: Int,
        operation: () throws -> Void
    ) rethrows -> BenchmarkResult {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { try operation() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return BenchmarkResult(iterations: iterations, elapsedNanoseconds: elapsed)
    }

    private static func makeObservation(
        reference: ServerMapReference,
        frameID: UInt64
    ) -> FrameObservationEnvelope {
        FrameObservationEnvelope(
            schemaVersion: 1,
            map: reference,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            frameID: frameID,
            capturedAt: 123.5,
            image: EncodedImageGeometry(
                width: 1_280,
                height: 960,
                orientation: .right,
                camera: .rearWide
            ),
            intrinsics: Matrix3x3Record(values: [
                800, 0, 0,
                0, 800, 0,
                640, 480, 1
            ]),
            worldFromCamera: Matrix4x4Record(matrix_identity_float4x4),
            tracking: .normal,
            depth: nil
        )
    }

    private static func makeResponse(
        for observation: FrameObservationEnvelope
    ) -> ServerLocalizationResponse {
        var inliers: [ServerImagePoint] = []
        inliers.reserveCapacity(64)
        for index in 0..<64 {
            let column = index % 16
            let row = index / 16
            let x = Float(80 + column * 60)
            let y = Float(80 + row * 80)
            inliers.append(
                ServerImagePoint(
                    x: x,
                    y: y,
                    mapLandmarkID: UInt64(index),
                    mapPosition: Vector3Record(
                        x: (x - 640) * 2 / 800,
                        y: -(y - 480) * 2 / 800,
                        z: -2
                    )
                )
            )
        }
        return ServerLocalizationResponse(
            schemaVersion: 1,
            result: ServerLocalizationResult(
                schemaVersion: 1,
                map: observation.map,
                sessionID: observation.sessionID,
                frameID: observation.frameID,
                capturedAt: observation.capturedAt,
                mapFromCamera: Matrix4x4Record(matrix_identity_float4x4),
                verification: .visualPnP,
                quality: LocalizationQualityRecord(
                    inlierCount: 64,
                    inlierRatio: 0.64,
                    medianReprojectionErrorPixels: 0,
                    depthOverlapRatio: nil,
                    depthRMSEMeters: nil
                )
            ),
            inliers: inliers
        )
    }

    private static func syntheticJPEG(byteCount: Int) -> Data {
        var data = Data([0xFF, 0xD8])
        data.append(Data(repeating: 0x55, count: max(0, byteCount - 4)))
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }
}

private struct BenchmarkResult {
    let iterations: Int
    let elapsedNanoseconds: UInt64

    var dictionary: [String: Any] {
        [
            "iterations": iterations,
            "elapsedMilliseconds": Double(elapsedNanoseconds) / 1_000_000,
            "nanosecondsPerOperation": Double(elapsedNanoseconds) / Double(iterations)
        ]
    }
}
