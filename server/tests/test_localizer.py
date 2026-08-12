from __future__ import annotations

import base64
import math
from uuid import UUID

import cv2
import numpy as np

from housemapper_server.contracts import MapReference, QueryObservation
from housemapper_server.features import FeatureMatches, ImageFeatures
from housemapper_server.errors import LocalizationError
from housemapper_server.geometry import pose_delta, project_map_points
from housemapper_server.localizer import LocalizationConfiguration, MetricVisualLocalizer
from housemapper_server.map_store import ServerMap


class GeometricBackend:
    feature_identity = "geometric-test-feature"
    matcher_identity = "geometric-test-matcher"
    descriptor_dimension = 16

    def __init__(self, query_features: ImageFeatures) -> None:
        self.query_features = query_features

    def extract(self, image_bgr: np.ndarray) -> ImageFeatures:
        return self.query_features

    def match(self, first: ImageFeatures, second: ImageFeatures) -> FeatureMatches:
        count = min(len(first.keypoints), len(second.keypoints))
        indices = np.column_stack((np.arange(count), np.arange(count))).astype(np.int32)
        return FeatureMatches(indices, np.ones(count, dtype=np.float32))


def request(reference: MapReference, intrinsics: np.ndarray) -> QueryObservation:
    image = np.zeros((960, 1280, 3), dtype=np.uint8)
    ok, jpeg = cv2.imencode(".jpg", image)
    assert ok
    def column_major(value: np.ndarray): return value.reshape(-1, order="F").tolist()
    return QueryObservation.parse({
        "schemaVersion": 1,
        "observation": {
            "schemaVersion": 1,
            "map": reference.json(),
            "sessionID": "00000000-0000-0000-0000-000000000001",
            "frameID": 4,
            "capturedAt": 50.25,
            "image": {"width": 1280, "height": 960, "orientation": "right", "camera": "rearWide"},
            "intrinsics": {"values": column_major(intrinsics)},
            "worldFromCamera": {"values": column_major(np.eye(4))},
            "tracking": "normal",
            "depth": None,
        },
        "jpegImage": base64.b64encode(jpeg.tobytes()).decode(),
    })


def test_localizer_returns_real_metric_inliers_compatible_with_client_contract() -> None:
    rng = np.random.default_rng(11)
    reference = MapReference(UUID("11111111-2222-3333-4444-555555555555"), UUID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    intrinsics = np.array([[900, 0, 640], [0, 900, 480], [0, 0, 1]], dtype=float)
    angle = math.radians(8)
    expected = np.eye(4)
    expected[:3, :3] = [[math.cos(angle), 0, math.sin(angle)], [0, 1, 0], [-math.sin(angle), 0, math.cos(angle)]]
    expected[:3, 3] = [0.4, 0.1, -0.2]
    positions = np.column_stack((rng.uniform(-2, 2, 80), rng.uniform(-1, 1, 80), rng.uniform(-7, -3, 80))).astype(np.float32)
    pixels, _ = project_map_points(positions, intrinsics, expected)
    descriptors = rng.normal(size=(80, 16)).astype(np.float32)
    descriptors /= np.linalg.norm(descriptors, axis=1, keepdims=True)
    query_features = ImageFeatures(pixels.astype(np.float32), descriptors, np.ones(80, dtype=np.float32), np.ones(16, dtype=np.float32) / 4, (1280, 960))
    server_map = ServerMap(
        reference,
        {"reconstruction": "metric", "retrieval": "vlad", "localFeatures": GeometricBackend.feature_identity, "matcher": GeometricBackend.matcher_identity},
        (UUID(int=1), UUID(int=2)),
        np.array([[1280, 960], [1280, 960]], dtype=np.int32),
        np.array([0, 80, 160], dtype=np.int64),
        np.concatenate((pixels, pixels)).astype(np.float32),
        np.concatenate((descriptors, descriptors)).astype(np.float32),
        np.tile(np.arange(1, 81, dtype=np.int64), 2),
        np.ones((2, 64), dtype=np.float32) / 8,
        np.zeros((4, 16), dtype=np.float32),
        np.arange(1, 81, dtype=np.int64),
        positions,
        descriptors,
        np.full(80, 2, dtype=np.int16),
    )
    # All descriptors assign to the first zero center; map/query VLAD is exact.
    localizer = MetricVisualLocalizer(
        server_map,
        GeometricBackend(query_features),
        LocalizationConfiguration(retrieval_count=2, minimum_correspondences=50, minimum_inliers=40),
    )

    output = localizer.localize(request(reference, intrinsics))
    recovered_values = output.response["result"]["mapFromCamera"]["values"]
    recovered = np.asarray(recovered_values).reshape((4, 4), order="F")
    translation, rotation = pose_delta(recovered, expected)

    assert translation < 1e-3
    assert math.degrees(rotation) < 0.01
    assert output.metrics.inliers == 80
    assert output.metrics.retrieved_keyframe_ids == (
        str(server_map.keyframe_ids[0]).upper(),
        str(server_map.keyframe_ids[1]).upper(),
    )
    assert len(output.metrics.retrieval_similarities) == 2
    assert len(output.response["inliers"]) == 80
    assert output.response["result"]["verification"] == "visualPnP"
    assert output.response["result"]["quality"]["depthOverlapRatio"] is None


def test_localizer_rejection_reports_the_measured_correspondence_stage() -> None:
    rng = np.random.default_rng(12)
    reference = MapReference(UUID(int=1), UUID(int=2))
    intrinsics = np.array([[900, 0, 640], [0, 900, 480], [0, 0, 1]], dtype=float)
    positions = np.column_stack((rng.uniform(-2, 2, 20), rng.uniform(-1, 1, 20), rng.uniform(-7, -3, 20))).astype(np.float32)
    pixels, _ = project_map_points(positions, intrinsics, np.eye(4))
    descriptors = rng.normal(size=(20, 16)).astype(np.float32)
    descriptors /= np.linalg.norm(descriptors, axis=1, keepdims=True)
    features = ImageFeatures(pixels, descriptors, np.ones(20, dtype=np.float32), np.ones(16, dtype=np.float32) / 4, (1280, 960))
    server_map = ServerMap(
        reference,
        {"reconstruction": "metric", "retrieval": "vlad", "localFeatures": GeometricBackend.feature_identity, "matcher": GeometricBackend.matcher_identity},
        (UUID(int=3), UUID(int=4)),
        np.array([[1280, 960], [1280, 960]], dtype=np.int32),
        np.array([0, 20, 40], dtype=np.int64),
        np.concatenate((pixels, pixels)),
        np.concatenate((descriptors, descriptors)),
        np.tile(np.arange(1, 21, dtype=np.int64), 2),
        np.ones((2, 64), dtype=np.float32) / 8,
        np.zeros((4, 16), dtype=np.float32),
        np.arange(1, 21, dtype=np.int64),
        positions,
        descriptors,
        np.full(20, 2, dtype=np.int16),
    )
    localizer = MetricVisualLocalizer(server_map, GeometricBackend(features))

    try:
        localizer.localize(request(reference, intrinsics))
        raise AssertionError("expected weak correspondence geometry to be rejected")
    except LocalizationError as error:
        assert error.stage == "correspondence"
        assert error.diagnostics["extractedKeypoints"] == 20
        assert error.diagnostics["rawMatches"] == 40
        assert error.diagnostics["uniqueCorrespondences"] == 20
