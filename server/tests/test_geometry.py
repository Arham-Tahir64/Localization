from __future__ import annotations

import math

import numpy as np

from housemapper_server.geometry import (
    map_from_ar_camera_from_cv_pose,
    filter_calibrated_pair_matches,
    pose_delta,
    project_map_points,
    solve_metric_pnp,
    triangulate_track,
)


def pose(x: float, y: float, z: float, yaw_degrees: float = 0) -> np.ndarray:
    angle = math.radians(yaw_degrees)
    value = np.eye(4, dtype=np.float64)
    value[:3, :3] = np.array([
        [math.cos(angle), 0, math.sin(angle)],
        [0, 1, 0],
        [-math.sin(angle), 0, math.cos(angle)],
    ])
    value[:3, 3] = [x, y, z]
    return value


def intrinsics() -> np.ndarray:
    return np.array([[920, 0, 640], [0, 915, 480], [0, 0, 1]], dtype=np.float64)


def test_triangulation_preserves_metric_arkit_map_frame() -> None:
    expected = np.array([0.4, 0.2, -4.0])
    observations = []
    for camera in (pose(-0.8, 0, 0), pose(0, 0, 0), pose(0.9, 0.1, -0.1)):
        pixels, depth = project_map_points(expected[None], intrinsics(), camera)
        assert depth[0] > 0
        observations.append((pixels[0], intrinsics(), camera))

    result = triangulate_track(observations)

    assert result is not None
    point, residuals = result
    assert np.linalg.norm(point - expected) < 1e-4
    assert np.max(residuals) < 1e-3


def test_triangulation_rejects_negligible_parallax() -> None:
    point = np.array([0.2, 0.1, -8.0])
    observations = []
    for camera in (pose(0, 0, 0), pose(0.01, 0, 0)):
        pixels, _ = project_map_points(point[None], intrinsics(), camera)
        observations.append((pixels[0], intrinsics(), camera))

    assert triangulate_track(observations, minimum_parallax_degrees=1.25) is None


def test_batched_pair_gate_matches_metric_triangulation_semantics() -> None:
    rng = np.random.default_rng(4)
    points = np.column_stack((rng.uniform(-2, 2, 300), rng.uniform(-1, 1, 300), rng.uniform(-7, -3, 300)))
    first_pose = pose(-0.6, 0, 0)
    second_pose = pose(0.6, 0, 0)
    first, _ = project_map_points(points, intrinsics(), first_pose)
    second, _ = project_map_points(points, intrinsics(), second_pose)
    first += rng.normal(0, 0.25, first.shape)
    second += rng.normal(0, 0.25, second.shape)
    second[:30] = rng.uniform([0, 0], [1280, 960], (30, 2))

    mask = filter_calibrated_pair_matches(
        first, second, intrinsics(), intrinsics(), first_pose, second_pose
    )

    assert np.count_nonzero(mask[:30]) == 0
    assert np.count_nonzero(mask[30:]) >= 265


def test_ransac_pnp_recovers_full_arkit_pose_with_outliers() -> None:
    rng = np.random.default_rng(20260811)
    expected = pose(1.1, 0.35, -0.8, yaw_degrees=13)
    points = np.column_stack((
        rng.uniform(-2.5, 3.5, 120),
        rng.uniform(-1.2, 1.8, 120),
        rng.uniform(-8.0, -3.0, 120),
    ))
    pixels, depth = project_map_points(points, intrinsics(), expected)
    assert np.all(depth > 0)
    pixels += rng.normal(0, 0.35, pixels.shape)
    pixels[:20] = rng.uniform([0, 0], [1280, 960], (20, 2))

    result = solve_metric_pnp(pixels, points, intrinsics())
    translation, rotation = pose_delta(result.map_from_camera, expected)

    assert len(result.inlier_indices) >= 95
    assert translation < 0.02
    assert math.degrees(rotation) < 0.25
    assert np.median(result.residuals_pixels) < 1.0


def test_opencv_pose_roundtrip_has_correct_arkit_axis_convention() -> None:
    expected = pose(-0.4, 0.7, 1.2, yaw_degrees=-27)
    cv_from_map = np.diag([1.0, -1.0, -1.0, 1.0]) @ np.linalg.inv(expected)
    import cv2
    rotation, _ = cv2.Rodrigues(cv_from_map[:3, :3])

    recovered = map_from_ar_camera_from_cv_pose(rotation, cv_from_map[:3, 3])
    translation, angle = pose_delta(recovered, expected)
    assert translation < 1e-8
    assert angle < 1e-8
