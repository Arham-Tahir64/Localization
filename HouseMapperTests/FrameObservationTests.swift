import XCTest
import simd
@testable import HouseMapper

final class FrameObservationTests: XCTestCase {
    func testServerErrorDetailBoundsUntrustedDisplayTextAndStages() {
        XCTAssertTrue(
            ServerLocalizationErrorDetail(
                detail: "not enough geometry",
                stage: "correspondence"
            ).isSafeForDisplay
        )
        XCTAssertFalse(
            ServerLocalizationErrorDetail(
                detail: String(repeating: "x", count: 501),
                stage: "pnp"
            ).isSafeForDisplay
        )
        XCTAssertFalse(
            ServerLocalizationErrorDetail(
                detail: "internal path",
                stage: "stackTrace"
            ).isSafeForDisplay
        )
    }

    func testDefaultKeyframeSelectorDoesNotTreatARKitSparseCloudAsLearnedFeatures() {
        var selector = MappingKeyframeSelector()

        XCTAssertFalse(
            selector.reserveIfEligible(
                timestamp: 1,
                mapFromCamera: matrix_identity_float4x4,
                tracking: .normal,
                featureCount: 79
            )
        )
        XCTAssertTrue(
            selector.reserveIfEligible(
                timestamp: 1,
                mapFromCamera: matrix_identity_float4x4,
                tracking: .normal,
                featureCount: 80
            )
        )
    }

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

    func testServerMapManifestRoundTripBindsMapVersionAndEndpoint() throws {
        let manifest = makeServerManifest(endpoint: "https://mapper.example/localize")

        let decoded = try ServerMapManifest.decode(
            manifest.encodedJSON(),
            expectedMapID: manifest.map.mapID
        )

        XCTAssertEqual(decoded, manifest)
        XCTAssertThrowsError(
            try ServerMapManifest.decode(manifest.encodedJSON(), expectedMapID: UUID())
        ) { error in
            XCTAssertEqual(error as? ServerMapManifestError, .mapIdentifierMismatch)
        }
    }

    func testServerMapManifestAllowsTLSOrBonjourLocalHTTPOnly() throws {
        XCTAssertNoThrow(
            try makeServerManifest(endpoint: "https://mapper.example:8443/v1/localize")
                .validate(expectedMapID: uuid(1))
        )
        XCTAssertNoThrow(
            try makeServerManifest(endpoint: "http://mapping-mac.local:8080/localize")
                .validate(expectedMapID: uuid(1))
        )
        for endpoint in [
            "http://192.168.1.10:8080/localize",
            "http://mapper.example/localize",
            "https://user:secret@mapper.example/localize",
            "https://mapper.example/localize?map=other",
            "https://mapper.example/localize#fragment"
        ] {
            XCTAssertThrowsError(
                try makeServerManifest(endpoint: endpoint).validate(expectedMapID: uuid(1)),
                "Expected rejection for \(endpoint)"
            )
        }
    }

    func testServerResponseRequiresRealInBoundsInlierCoordinates() throws {
        let observation = makeObservation()
        let valid = makeResponse(for: observation, inlierCount: 48)
        XCTAssertNoThrow(try valid.validate(for: observation))

        let outside = ServerLocalizationResponse(
            schemaVersion: 1,
            result: valid.result,
            inliers: [
                ServerImagePoint(
                    x: 1_920,
                    y: 500,
                    mapLandmarkID: 1,
                    mapPosition: Vector3Record(x: 0, y: 0, z: 0)
                )
            ]
        )
        XCTAssertThrowsError(try outside.validate(for: observation)) { error in
            XCTAssertEqual(error as? ServerLocalizationContractError, .invalidInlierPoint)
        }

        let overreported = ServerLocalizationResponse(
            schemaVersion: 1,
            result: valid.result,
            inliers: makeInliers(count: valid.result.quality.inlierCount + 1)
        )
        XCTAssertThrowsError(try overreported.validate(for: observation)) { error in
            XCTAssertEqual(error as? ServerLocalizationContractError, .inlierCountMismatch)
        }
    }

    func testServerResponseRejects2D3DInlierThatDoesNotReproject() {
        let observation = makeObservation()
        let valid = makeResponse(for: observation, inlierCount: 48)
        var corrupted = valid.inliers
        let first = corrupted[0]
        corrupted[0] = ServerImagePoint(
            x: first.x + 100,
            y: first.y,
            mapLandmarkID: first.mapLandmarkID,
            mapPosition: first.mapPosition
        )
        let response = ServerLocalizationResponse(
            schemaVersion: 1,
            result: valid.result,
            inliers: corrupted
        )

        XCTAssertThrowsError(try response.validate(for: observation)) { error in
            XCTAssertEqual(
                error as? ServerLocalizationContractError,
                .inlierGeometryMismatch
            )
        }
    }

    func testServerAcceptancePolicyRejectsWeakOrUnverifiedMatches() {
        let observation = makeObservation()
        let policy = ServerLocalizationAcceptancePolicy()

        XCTAssertTrue(policy.accepts(makeResponse(for: observation, inlierCount: 48)))
        XCTAssertFalse(policy.accepts(makeResponse(for: observation, inlierCount: 39)))

        let weakQuality = LocalizationQualityRecord(
            inlierCount: 80,
            inlierRatio: 0.1,
            medianReprojectionErrorPixels: 6,
            depthOverlapRatio: 0.05,
            depthRMSEMeters: 0.5
        )
        XCTAssertFalse(
            policy.accepts(makeResponse(for: observation, inlierCount: 48, quality: weakQuality))
        )
    }

    func testServerPoseConfirmationRequiresTwoConsistentMetricBridges() throws {
        let expectedMapFromWorld = transform(translation: SIMD3(3, 0.2, -4), yaw: .pi / 5)
        let first = makeObservation(frameID: 42, capturedAt: 100)
        let secondWorldFromCamera = transform(translation: SIMD3(0.12, 0, -0.08), yaw: 0.03)
        let second = makeObservation(
            worldFromCamera: secondWorldFromCamera,
            frameID: 43,
            capturedAt: 101
        )
        var gate = ServerPoseConfirmationGate()

        let firstBridge = try gate.consider(
            response: makeResponse(
                for: first,
                mapFromCamera: simd_mul(expectedMapFromWorld, matrix_identity_float4x4)
            ),
            observation: first,
            policy: ServerLocalizationAcceptancePolicy()
        )
        let confirmedBridge = try gate.consider(
            response: makeResponse(
                for: second,
                mapFromCamera: simd_mul(expectedMapFromWorld, secondWorldFromCamera)
            ),
            observation: second,
            policy: ServerLocalizationAcceptancePolicy()
        )

        XCTAssertNil(firstBridge)
        XCTAssertEqual(gate.consistentResultCount, 2)
        assertMatrix(try XCTUnwrap(confirmedBridge), equals: expectedMapFromWorld)
    }

    func testServerPoseConfirmationRejectsReorderedFrame() throws {
        let first = makeObservation(frameID: 42, capturedAt: 100)
        let stale = makeObservation(frameID: 41, capturedAt: 99)
        var gate = ServerPoseConfirmationGate()
        _ = try gate.consider(
            response: makeResponse(for: first),
            observation: first,
            policy: ServerLocalizationAcceptancePolicy()
        )

        XCTAssertThrowsError(
            try gate.consider(
                response: makeResponse(for: stale),
                observation: stale,
                policy: ServerLocalizationAcceptancePolicy()
            )
        ) { error in
            XCTAssertEqual(error as? ServerLocalizationContractError, .nonmonotonicFrame)
        }
    }

    func testServerPoseConfirmationExpiresAcrossLongCaptureGap() throws {
        let first = makeObservation(frameID: 42, capturedAt: 100)
        let late = makeObservation(frameID: 43, capturedAt: 107)
        var gate = ServerPoseConfirmationGate(maximumCaptureInterval: 6)
        _ = try gate.consider(
            response: makeResponse(for: first),
            observation: first,
            policy: ServerLocalizationAcceptancePolicy()
        )

        let result = try gate.consider(
            response: makeResponse(for: late),
            observation: late,
            policy: ServerLocalizationAcceptancePolicy()
        )

        XCTAssertNil(result)
        XCTAssertEqual(gate.consistentResultCount, 1)
    }

    func testServerRequestRejectsEmptyImageBytes() {
        XCTAssertThrowsError(
            try ServerLocalizationRequest(observation: makeObservation(), jpegImage: Data())
        ) { error in
            XCTAssertEqual(error as? ServerLocalizationContractError, .emptyImage)
        }
    }

    func testServerRequestPreservesCalibratedEnvelopeAndJPEGExactly() throws {
        let observation = makeObservation()
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])

        let request = try ServerLocalizationRequest(
            observation: observation,
            jpegImage: jpeg
        )
        let decoded = try JSONDecoder().decode(
            ServerLocalizationRequest.self,
            from: request.encodedJSON()
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.observation, observation)
        XCTAssertEqual(decoded.jpegImage, jpeg)
    }

    func testJPEGOnlyRequestRejectsServerClaimOfDepthVerification() throws {
        let observation = makeObservation()
        let request = try ServerLocalizationRequest(
            observation: observation,
            jpegImage: Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        )

        XCTAssertThrowsError(
            try request.validate(response: makeResponse(for: observation))
        ) { error in
            XCTAssertEqual(
                error as? ServerLocalizationContractError,
                .unexpectedDepthVerification
            )
        }
    }

    private func makeObservation(
        worldFromCamera: simd_float4x4 = matrix_identity_float4x4,
        frameID: UInt64 = 42,
        capturedAt: TimeInterval = 123.5
    ) -> FrameObservationEnvelope {
        FrameObservationEnvelope(
            schemaVersion: 1,
            map: ServerMapReference(mapID: uuid(1), versionID: uuid(2)),
            sessionID: uuid(3),
            frameID: frameID,
            capturedAt: capturedAt,
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

    private func makeServerManifest(endpoint: String) -> ServerMapManifest {
        ServerMapManifest(
            map: ServerMapReference(mapID: uuid(1), versionID: uuid(2)),
            createdAt: Date(timeIntervalSince1970: 123),
            queryEndpoint: endpoint,
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
    }

    private func makeResponse(
        for observation: FrameObservationEnvelope,
        inlierCount: Int = 48,
        mapFromCamera: simd_float4x4 = matrix_identity_float4x4,
        quality: LocalizationQualityRecord? = nil
    ) -> ServerLocalizationResponse {
        let result = ServerLocalizationResult(
            schemaVersion: 1,
            map: observation.map,
            sessionID: observation.sessionID,
            frameID: observation.frameID,
            capturedAt: observation.capturedAt,
            mapFromCamera: Matrix4x4Record(mapFromCamera),
            verification: .visualAndDepth,
            quality: quality ?? LocalizationQualityRecord(
                inlierCount: inlierCount,
                inlierRatio: 0.62,
                medianReprojectionErrorPixels: 0,
                depthOverlapRatio: 0.55,
                depthRMSEMeters: 0.04
            )
        )
        return ServerLocalizationResponse(
            schemaVersion: 1,
            result: result,
            inliers: makeInliers(count: inlierCount, mapFromCamera: mapFromCamera)
        )
    }

    private func makeInliers(
        count: Int,
        mapFromCamera: simd_float4x4 = matrix_identity_float4x4
    ) -> [ServerImagePoint] {
        var points: [ServerImagePoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let column = index % 40
            let row = index / 40
            let x = Float(100 + column * 30)
            let y = Float(100 + row * 30)
            let cameraPoint = SIMD4(
                (x - 960) * 2 / 1_100,
                -(y - 540) * 2 / 1_100,
                -2,
                1
            )
            let mapPoint = simd_mul(mapFromCamera, cameraPoint)
            points.append(
                ServerImagePoint(
                    x: x,
                    y: y,
                    mapLandmarkID: UInt64(index),
                    mapPosition: Vector3Record(
                        x: mapPoint.x,
                        y: mapPoint.y,
                        z: mapPoint.z
                    )
                )
            )
        }
        return points
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
