import XCTest
import simd
@testable import HouseMapper

final class CoordinateFramesTests: XCTestCase {
    func testARWorldMapIdentityLeavesCameraPoseInMapFrame() {
        let worldFromCamera = transform(
            translation: SIMD3(2.0, 1.2, -3.5),
            yaw: .pi / 3
        )

        let mapFromCamera = CoordinateFrames.mapFromCamera(
            mapFromWorld: matrix_identity_float4x4,
            worldFromCamera: worldFromCamera
        )

        assertMatrix(mapFromCamera, equals: worldFromCamera)
    }

    func testCustomAlignmentRecoversKnownMapFromWorldTransform() {
        let expectedMapFromWorld = transform(
            translation: SIMD3(8.0, 0.4, -2.0),
            yaw: -.pi / 4
        )
        let worldFromCameraAtMatch = transform(
            translation: SIMD3(-1.0, 1.5, 3.0),
            yaw: .pi / 6
        )
        let globalMapFromCamera = simd_mul(
            expectedMapFromWorld,
            worldFromCameraAtMatch
        )

        let actualMapFromWorld = CoordinateFrames.mapFromWorld(
            globalMapFromCamera: globalMapFromCamera,
            worldFromCameraAtMatch: worldFromCameraAtMatch
        )

        assertMatrix(actualMapFromWorld, equals: expectedMapFromWorld)
    }

    func testWorldCameraTransformsAreMutualInverses() {
        let cameraFromWorld = transform(
            translation: SIMD3(0.8, -1.1, 4.2),
            yaw: .pi / 2
        )
        let worldFromCamera = CoordinateFrames.worldFromCamera(cameraFromWorld)

        assertMatrix(
            simd_mul(cameraFromWorld, worldFromCamera),
            equals: matrix_identity_float4x4
        )
    }

    private func transform(
        translation: SIMD3<Float>,
        yaw: Float
    ) -> simd_float4x4 {
        var matrix = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        matrix.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
        return matrix
    }

    private func assertMatrix(
        _ actual: simd_float4x4,
        equals expected: simd_float4x4,
        accuracy: Float = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(
                    actual[column][row],
                    expected[column][row],
                    accuracy: accuracy,
                    file: file,
                    line: line
                )
            }
        }
    }
}

