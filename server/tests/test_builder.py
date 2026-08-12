from __future__ import annotations

from pathlib import Path
from uuid import UUID

import cv2
import numpy as np

from housemapper_server.builder import BuildConfiguration, build_metric_map
from housemapper_server.contracts import ImageGeometry, Keyframe, MappingPackage
from housemapper_server.features import FeatureMatches, ImageFeatures
from housemapper_server.geometry import project_map_points
from housemapper_server.map_store import load_server_map


class ScriptedMetricBackend:
    feature_identity = "scripted-metric-features"
    matcher_identity = "scripted-identity-matcher"
    descriptor_dimension = 16

    def __init__(self, features: list[ImageFeatures]) -> None:
        self.features = features
        self.extract_index = 0

    def extract(self, image_bgr: np.ndarray) -> ImageFeatures:
        value = self.features[self.extract_index]
        self.extract_index += 1
        return value

    def match(self, first: ImageFeatures, second: ImageFeatures) -> FeatureMatches:
        count = min(len(first.keypoints), len(second.keypoints))
        return FeatureMatches(
            np.column_stack((np.arange(count), np.arange(count))).astype(np.int32),
            np.ones(count, dtype=np.float32),
        )


def test_builder_preserves_metric_map_tracks_through_immutable_reload(tmp_path: Path) -> None:
    rng = np.random.default_rng(17)
    intrinsics = np.array([[700, 0, 320], [0, 700, 240], [0, 0, 1]], dtype=float)
    positions = np.column_stack((
        rng.uniform(-1.5, 1.5, 30),
        rng.uniform(-0.8, 0.8, 30),
        rng.uniform(-5.5, -3.0, 30),
    )).astype(np.float32)
    descriptors = rng.normal(size=(30, 16)).astype(np.float32)
    descriptors /= np.linalg.norm(descriptors, axis=1, keepdims=True)

    keyframes = []
    features = []
    for index, x in enumerate((-0.7, 0.0, 0.7)):
        image_path = tmp_path / f"{index}.jpg"
        assert cv2.imwrite(str(image_path), np.zeros((480, 640, 3), dtype=np.uint8))
        map_from_camera = np.eye(4)
        map_from_camera[0, 3] = x
        pixels, depth = project_map_points(positions, intrinsics, map_from_camera)
        assert np.all(depth > 0)
        feature = ImageFeatures(
            pixels.astype(np.float32),
            descriptors,
            np.ones(30, dtype=np.float32),
            np.mean(descriptors, axis=0),
            (640, 480),
        )
        features.append(feature)
        keyframes.append(Keyframe(
            UUID(int=index + 1),
            index + 1,
            float(index + 1),
            ImageGeometry(640, 480, "right", "rearWide"),
            intrinsics,
            map_from_camera,
            900,
            image_path,
        ))
    package = MappingPackage(
        tmp_path,
        UUID("11111111-2222-3333-4444-555555555555"),
        "Synthetic Metric House",
        tuple(keyframes),
    )

    result = build_metric_map(
        package,
        ScriptedMetricBackend(features),
        tmp_path / "maps",
        "http://mapping-mac.local:8080/localize",
        BuildConfiguration(
            sequential_window=2,
            nearest_pose_neighbors=2,
            retrieval_neighbors=2,
            minimum_pair_inliers=12,
            minimum_landmarks=20,
            vlad_cluster_count=4,
        ),
        progress=lambda _: None,
    )
    loaded = load_server_map(result.directory)

    assert result.metrics.accepted_pairs == 3
    assert result.metrics.landmarks == 30
    assert len(loaded.landmark_ids) == 30
    # Landmark ordering follows tracks, not source order; nearest-neighbour
    # distance proves that the same metric geometry survived serialization.
    distances = np.linalg.norm(
        loaded.landmark_positions[:, None, :] - positions[None, :, :],
        axis=2,
    )
    assert np.max(np.min(distances, axis=1)) < 1e-4
