import XCTest
import simd
@testable import HouseMapper

final class FrameObservationTests: XCTestCase {
    func testKeyframeSelectorUsesMetricTranslationRotationAndQualityGates() {
        var selector = MappingKeyframeSelector(
            minimumTranslationMeters: 0.5,
            minimumRotationRadians: .pi / 6,
            minimumTimeInterval: 0.75,
            minimumFeatureCount: 250,
            maximumKeyframeCount: 3
        )
        let identity = matrix_identity_float4x4

        XCTAssertTrue(selector.reserveIfEligible(timestamp: 1, mapFromCamera: identity, tracking: .normal, featureCount: 500))
        selector.commitMostRecentReservation()
        XCTAssertFalse(selector.reserveIfEligible(timestamp: 1.2, mapFromCamera: translated(x: 2), tracking: .normal, featureCount: 500))
        XCTAssertFalse(selector.reserveIfEligible(timestamp: 2, mapFromCamera: translated(x: 0.2), tracking: .normal, featureCount: 500))
        XCTAssertTrue(selector.reserveIfEligible(timestamp: 2, mapFromCamera: translated(x: 0.6), tracking: .normal, featureCount: 500))
        selector.commitMostRecentReservation()
        XCTAssertFalse(selector.reserveIfEligible(timestamp: 3, mapFromCamera: translated(x: 1.2), tracking: .limitedInsufficientFeatures, featureCount: 500))
        XCTAssertFalse(selector.reserveIfEligible(timestamp: 3, mapFromCamera: translated(x: 1.2), tracking: .normal, featureCount: 100))
        XCTAssertTrue(selector.reserveIfEligible(timestamp: 3, mapFromCamera: rotatedY(.pi / 3, translatedX: 0.6), tracking: .normal, featureCount: 500))
        selector.commitMostRecentReservation()
        XCTAssertFalse(selector.reserveIfEligible(timestamp: 4, mapFromCamera: translated(x: 3), tracking: .normal, featureCount: 500))
        XCTAssertEqual(selector.reservedCount, 3)
    }

    func testKeyframeSelectorRollbackRestoresPreviousNoveltyReference() {
        var selector = MappingKeyframeSelector(
            minimumTranslationMeters: 0.5,
            minimumRotationRadians: .pi,
            minimumTimeInterval: 0,
            minimumFeatureCount: 1,
            maximumKeyframeCount: 3
        )
        XCTAssertTrue(selector.reserveIfEligible(timestamp: 1, mapFromCamera: translated(x: 0), tracking: .normal, featureCount: 10))
        selector.commitMostRecentReservation()
        XCTAssertTrue(selector.reserveIfEligible(timestamp: 2, mapFromCamera: translated(x: 0.6), tracking: .normal, featureCount: 10))
        selector.cancelMostRecentReservation()

        XCTAssertTrue(selector.reserveIfEligible(timestamp: 3, mapFromCamera: translated(x: 0.6), tracking: .normal, featureCount: 10))
        XCTAssertEqual(selector.reservedCount, 2)
    }

    func testKeyframeManifestRoundTripPreservesCalibrationAndMapFrame() throws {
        let mapID = UUID()
        let capture = PendingMappingKeyframe(
            id: UUID(),
            frameID: 42,
            capturedAt: 12.5,
            image: EncodedImageGeometry(width: 1_280, height: 960, orientation: .right, camera: .rearWide),
            intrinsics: Matrix3x3Record(values: [800, 0, 0, 0, 800, 0, 640, 480, 1]),
            mapFromCamera: Matrix4x4Record(matrix_identity_float4x4),
            tracking: .normal,
            sourceFeatureCount: 900,
            imageData: Data([1, 2, 3])
        )
        let manifest = try MappingKeyframeManifest(mapID: mapID, captures: [capture])

        let data = try manifest.encodedJSON()
        let decoded = try MappingKeyframeManifest.decode(data, expectedMapID: mapID)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.keyframes.first?.imageFileName, "\(capture.id.uuidString).jpg")
        XCTAssertEqual(decoded.keyframes.first?.sourceFeatureCount, 900)
    }

    func testEnvelopeRoundTripsWithDepthMetadata() throws {
        let observation = makeObservation()

        let data = try JSONEncoder().encode(observation)
        let decoded = try JSONDecoder().decode(FrameObservationEnvelope.self, from: data)

        XCTAssertEqual(decoded, observation)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testMatchingResultEstablishesMapFromWorldTransform() throws {
        let worldFromCamera = transform(translation: SIMD3(1, 0.5, -2), yaw: .pi / 4)
        let expectedMapFromWorld = transform(translation: SIMD3(8, 0, 3), yaw: -.pi / 3)
        let observation = makeObservation(worldFromCamera: worldFromCamera)
        let result = makeResult(
            for: observation,
            mapFromCamera: simd_mul(expectedMapFromWorld, worldFromCamera)
        )

        let actualMapFromWorld = try result.mapFromWorld(for: observation)

        assertMatrix(actualMapFromWorld, equals: expectedMapFromWorld)
    }

    func testResultFromPreviousSessionIsRejected() {
        let observation = makeObservation()
        var result = makeResult(for: observation)
        result = ServerLocalizationResult(
            schemaVersion: result.schemaVersion,
            map: result.map,
            sessionID: UUID(),
            frameID: result.frameID,
            capturedAt: result.capturedAt,
            mapFromCamera: result.mapFromCamera,
            verification: result.verification,
            quality: result.quality
        )

        XCTAssertThrowsError(try result.mapFromWorld(for: observation)) { error in
            XCTAssertEqual(error as? FrameObservationError, .sessionMismatch)
        }
    }

    func testResultForWrongFrameOrMapVersionIsRejected() {
        let observation = makeObservation()
        let wrongFrame = ServerLocalizationResult(
            schemaVersion: 1,
            map: observation.map,
            sessionID: observation.sessionID,
            frameID: observation.frameID + 1,
            capturedAt: observation.capturedAt,
            mapFromCamera: Matrix4x4Record(matrix_identity_float4x4),
            verification: .visualPnP,
            quality: makeQuality()
        )
        let wrongMap = ServerLocalizationResult(
            schemaVersion: 1,
            map: ServerMapReference(mapID: observation.map.mapID, versionID: UUID()),
            sessionID: observation.sessionID,
            frameID: observation.frameID,
            capturedAt: observation.capturedAt,
            mapFromCamera: Matrix4x4Record(matrix_identity_float4x4),
            verification: .visualPnP,
            quality: makeQuality()
        )

        XCTAssertThrowsError(try wrongFrame.mapFromWorld(for: observation)) { error in
            XCTAssertEqual(error as? FrameObservationError, .frameMismatch)
        }
        XCTAssertThrowsError(try wrongMap.mapFromWorld(for: observation)) { error in
            XCTAssertEqual(error as? FrameObservationError, .mapVersionMismatch)
        }
    }

    func testEnvelopeValidationRejectsBadTimeIntrinsicsAndDimensions() {
        let valid = makeObservation()
        let badTime = FrameObservationEnvelope(
            schemaVersion: 1,
            map: valid.map,
            sessionID: valid.sessionID,
            frameID: valid.frameID,
            capturedAt: .nan,
            image: valid.image,
            intrinsics: valid.intrinsics,
            worldFromCamera: valid.worldFromCamera,
            tracking: valid.tracking,
            depth: valid.depth
        )
        let badIntrinsics = FrameObservationEnvelope(
            schemaVersion: 1,
            map: valid.map,
            sessionID: valid.sessionID,
            frameID: valid.frameID,
            capturedAt: valid.capturedAt,
            image: valid.image,
            intrinsics: Matrix3x3Record(values: [0, 0, 0, 0, 500, 0, 320, 240, 1]),
            worldFromCamera: valid.worldFromCamera,
            tracking: valid.tracking,
            depth: valid.depth
        )
        let badImage = FrameObservationEnvelope(
            schemaVersion: 1,
            map: valid.map,
            sessionID: valid.sessionID,
            frameID: valid.frameID,
            capturedAt: valid.capturedAt,
            image: EncodedImageGeometry(
                width: 0,
                height: valid.image.height,
                orientation: .right,
                camera: .rearWide
            ),
            intrinsics: valid.intrinsics,
            worldFromCamera: valid.worldFromCamera,
            tracking: valid.tracking,
            depth: valid.depth
        )

        XCTAssertThrowsError(try badTime.validate()) { error in
            XCTAssertEqual(error as? FrameObservationError, .invalidCaptureTime)
        }
        XCTAssertThrowsError(try badIntrinsics.validate()) { error in
            XCTAssertEqual(error as? FrameObservationError, .invalidCameraIntrinsics)
        }
        XCTAssertThrowsError(try badImage.validate()) { error in
            XCTAssertEqual(error as? FrameObservationError, .invalidImageDimensions)
        }
    }

    func testRigidTransformValidationRejectsProjectiveBottomRow() {
        var values = Matrix4x4Record(matrix_identity_float4x4).values
        values[3] = 0.25

        XCTAssertThrowsError(try Matrix4x4Record(values: values).validateRigidTransform()) { error in
            XCTAssertEqual(error as? FrameObservationError, .invalidRigidTransform)
        }
    }

    func testRigidTransformValidationRejectsScale() {
        var values = Matrix4x4Record(matrix_identity_float4x4).values
        values[0] = 2

        XCTAssertThrowsError(try Matrix4x4Record(values: values).validateRigidTransform()) { error in
            XCTAssertEqual(error as? FrameObservationError, .invalidRigidTransform)
        }
    }

    private func makeObservation(
        worldFromCamera: simd_float4x4 = matrix_identity_float4x4
    ) -> FrameObservationEnvelope {
        FrameObservationEnvelope(
            schemaVersion: 1,
            map: ServerMapReference(mapID: uuid(1), versionID: uuid(2)),
            sessionID: uuid(3),
            frameID: 42,
            capturedAt: 123.5,
            image: EncodedImageGeometry(
                width: 1_920,
                height: 1_080,
                orientation: .right,
                camera: .rearWide
            ),
            intrinsics: Matrix3x3Record(values: [
                1_100, 0, 0,
                0, 1_100, 0,
                960, 540, 1
            ]),
            worldFromCamera: Matrix4x4Record(worldFromCamera),
            tracking: .normal,
            depth: DepthObservationMetadata(
                width: 256,
                height: 192,
                format: .float32Meters,
                confidenceIncluded: true,
                imageFromDepth: Matrix3x3Record(values: [
                    7.5, 0, 0,
                    0, 5.625, 0,
                    0, 0, 1
                ])
            )
        )
    }

    private func makeResult(
        for observation: FrameObservationEnvelope,
        mapFromCamera: simd_float4x4 = matrix_identity_float4x4
    ) -> ServerLocalizationResult {
        ServerLocalizationResult(
            schemaVersion: 1,
            map: observation.map,
            sessionID: observation.sessionID,
            frameID: observation.frameID,
            capturedAt: observation.capturedAt,
            mapFromCamera: Matrix4x4Record(mapFromCamera),
            verification: .visualAndDepth,
            quality: makeQuality()
        )
    }

    private func makeQuality() -> LocalizationQualityRecord {
        LocalizationQualityRecord(
            inlierCount: 84,
            inlierRatio: 0.72,
            medianReprojectionErrorPixels: 1.4,
            depthOverlapRatio: 0.64,
            depthRMSEMeters: 0.035
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

    private func translated(x: Float) -> simd_float4x4 {
        transform(translation: SIMD3(x, 0, 0), yaw: 0)
    }

    private func rotatedY(_ yaw: Float, translatedX: Float) -> simd_float4x4 {
        transform(translation: SIMD3(translatedX, 0, 0), yaw: yaw)
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

    private func uuid(_ finalByte: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, finalByte
        ))
    }
}
