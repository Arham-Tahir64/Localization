from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Iterable

import cv2
import numpy as np

from .errors import ContractError, LocalizationError


# ARKit: +X right, +Y up, camera looks down -Z.
# OpenCV: +X right, +Y down, camera looks down +Z.
AR_CAMERA_FROM_CV_CAMERA = np.diag([1.0, -1.0, -1.0, 1.0])


def matrix_from_column_major(values: Iterable[float], dimension: int) -> np.ndarray:
    array = np.asarray(list(values), dtype=np.float64)
    if array.shape != (dimension * dimension,) or not np.all(np.isfinite(array)):
        raise ContractError(f"expected {dimension}x{dimension} finite column-major matrix")
    return array.reshape((dimension, dimension), order="F")


def column_major_values(matrix: np.ndarray) -> list[float]:
    value = np.asarray(matrix, dtype=np.float64)
    if value.shape != (4, 4) or not np.all(np.isfinite(value)):
        raise ContractError("pose must be a finite 4x4 matrix")
    return [float(component) for component in value.reshape(-1, order="F")]


def validate_intrinsics(matrix: np.ndarray, width: int, height: int) -> None:
    value = np.asarray(matrix, dtype=np.float64)
    if value.shape != (3, 3) or not np.all(np.isfinite(value)):
        raise ContractError("camera intrinsics must be a finite 3x3 matrix")
    fx, fy = value[0, 0], value[1, 1]
    cx, cy = value[0, 2], value[1, 2]
    if fx <= 0 or fy <= 0 or not (0 <= cx <= width) or not (0 <= cy <= height):
        raise ContractError("camera intrinsics are incompatible with the encoded image")
    if (
        abs(value[0, 1]) > 1e-3
        or abs(value[1, 0]) > 1e-3
        or abs(value[2, 0]) > 1e-6
        or abs(value[2, 1]) > 1e-6
        or abs(value[2, 2] - 1) > 1e-6
    ):
        raise ContractError("camera intrinsics have an invalid projective row")


def validate_rigid_transform(matrix: np.ndarray, *, tolerance: float = 0.015) -> None:
    value = np.asarray(matrix, dtype=np.float64)
    if value.shape != (4, 4) or not np.all(np.isfinite(value)):
        raise ContractError("pose must be a finite 4x4 matrix")
    if not np.allclose(value[3], [0, 0, 0, 1], atol=1e-4):
        raise ContractError("pose has an invalid homogeneous row")
    rotation = value[:3, :3]
    if not np.allclose(rotation.T @ rotation, np.eye(3), atol=tolerance):
        raise ContractError("pose rotation is not orthonormal")
    if np.linalg.det(rotation) <= 0.98:
        raise ContractError("pose rotation is not right handed")


def cv_camera_from_map(map_from_ar_camera: np.ndarray) -> np.ndarray:
    validate_rigid_transform(map_from_ar_camera)
    return AR_CAMERA_FROM_CV_CAMERA @ np.linalg.inv(map_from_ar_camera)


def map_from_ar_camera_from_cv_pose(
    rotation_vector: np.ndarray,
    translation_vector: np.ndarray,
) -> np.ndarray:
    rotation, _ = cv2.Rodrigues(np.asarray(rotation_vector, dtype=np.float64))
    cv_camera_from_map_pose = np.eye(4, dtype=np.float64)
    cv_camera_from_map_pose[:3, :3] = rotation
    cv_camera_from_map_pose[:3, 3] = np.asarray(translation_vector, dtype=np.float64).reshape(3)
    map_from_ar_camera = np.linalg.inv(AR_CAMERA_FROM_CV_CAMERA @ cv_camera_from_map_pose)
    validate_rigid_transform(map_from_ar_camera)
    return map_from_ar_camera


def projection_matrix(intrinsics: np.ndarray, map_from_ar_camera: np.ndarray) -> np.ndarray:
    return np.asarray(intrinsics, dtype=np.float64) @ cv_camera_from_map(map_from_ar_camera)[:3]


def project_map_points(
    points_map: np.ndarray,
    intrinsics: np.ndarray,
    map_from_ar_camera: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    points = np.asarray(points_map, dtype=np.float64).reshape((-1, 3))
    pose = cv_camera_from_map(map_from_ar_camera)
    camera_points = (pose[:3, :3] @ points.T + pose[:3, 3:4]).T
    depth = camera_points[:, 2]
    pixels_h = (np.asarray(intrinsics, dtype=np.float64) @ camera_points.T).T
    pixels = pixels_h[:, :2] / pixels_h[:, 2:3]
    return pixels, depth


def triangulate_track(
    observations: list[tuple[np.ndarray, np.ndarray, np.ndarray]],
    *,
    minimum_parallax_degrees: float = 1.25,
    maximum_median_error_pixels: float = 2.5,
    maximum_error_pixels: float = 6.0,
) -> tuple[np.ndarray, np.ndarray] | None:
    """Triangulate one landmark from (pixel, K, T_map_arCamera) observations."""
    if len(observations) < 2:
        return None
    rows: list[np.ndarray] = []
    centers: list[np.ndarray] = []
    rays: list[np.ndarray] = []
    for pixel, intrinsics, map_from_camera in observations:
        projection = projection_matrix(intrinsics, map_from_camera)
        x, y = np.asarray(pixel, dtype=np.float64)
        rows.extend([x * projection[2] - projection[0], y * projection[2] - projection[1]])
        centers.append(map_from_camera[:3, 3])
        cv_ray = np.linalg.inv(intrinsics) @ np.array([x, y, 1.0])
        ar_ray = np.array([cv_ray[0], -cv_ray[1], -cv_ray[2]])
        map_ray = map_from_camera[:3, :3] @ ar_ray
        rays.append(map_ray / np.linalg.norm(map_ray))

    greatest_parallax = 0.0
    for first in range(len(rays)):
        for second in range(first + 1, len(rays)):
            cosine = float(np.clip(np.dot(rays[first], rays[second]), -1, 1))
            greatest_parallax = max(greatest_parallax, math.degrees(math.acos(cosine)))
    if greatest_parallax < minimum_parallax_degrees:
        return None

    _, _, vh = np.linalg.svd(np.stack(rows), full_matrices=False)
    homogeneous = vh[-1]
    if abs(homogeneous[3]) < 1e-10:
        return None
    point = homogeneous[:3] / homogeneous[3]
    if not np.all(np.isfinite(point)):
        return None

    residuals: list[float] = []
    for pixel, intrinsics, map_from_camera in observations:
        projected, depth = project_map_points(point[None], intrinsics, map_from_camera)
        if depth[0] <= 0.03:
            return None
        residuals.append(float(np.linalg.norm(projected[0] - pixel)))
    errors = np.asarray(residuals)
    if np.median(errors) > maximum_median_error_pixels or np.max(errors) > maximum_error_pixels:
        return None
    return point.astype(np.float32), errors.astype(np.float32)


def filter_calibrated_pair_matches(
    first_pixels: np.ndarray,
    second_pixels: np.ndarray,
    first_intrinsics: np.ndarray,
    second_intrinsics: np.ndarray,
    first_map_from_camera: np.ndarray,
    second_map_from_camera: np.ndarray,
    *,
    minimum_parallax_degrees: float = 1.25,
    maximum_median_error_pixels: float = 2.5,
    maximum_error_pixels: float = 6.0,
) -> np.ndarray:
    """Vectorized metric triangulation gate for one calibrated image pair."""
    first = np.asarray(first_pixels, dtype=np.float64).reshape((-1, 2))
    second = np.asarray(second_pixels, dtype=np.float64).reshape((-1, 2))
    if len(first) != len(second):
        raise ContractError("paired keypoint arrays have different lengths")
    if not len(first):
        return np.zeros(0, dtype=bool)
    first_projection = projection_matrix(first_intrinsics, first_map_from_camera)
    second_projection = projection_matrix(second_intrinsics, second_map_from_camera)
    homogeneous = cv2.triangulatePoints(
        first_projection,
        second_projection,
        first.T,
        second.T,
    ).T
    valid_w = np.abs(homogeneous[:, 3]) > 1e-10
    points = np.full((len(first), 3), np.nan, dtype=np.float64)
    points[valid_w] = homogeneous[valid_w, :3] / homogeneous[valid_w, 3:4]
    finite = np.all(np.isfinite(points), axis=1)

    first_reprojection, first_depth = project_map_points(
        points, first_intrinsics, first_map_from_camera
    )
    second_reprojection, second_depth = project_map_points(
        points, second_intrinsics, second_map_from_camera
    )
    first_error = np.linalg.norm(first_reprojection - first, axis=1)
    second_error = np.linalg.norm(second_reprojection - second, axis=1)
    pair_errors = np.column_stack((first_error, second_error))

    first_rays = points - first_map_from_camera[:3, 3]
    second_rays = points - second_map_from_camera[:3, 3]
    first_norms = np.linalg.norm(first_rays, axis=1)
    second_norms = np.linalg.norm(second_rays, axis=1)
    ray_denominator = first_norms * second_norms
    ray_cosine = np.ones(len(points), dtype=np.float64)
    ray_valid = ray_denominator > 1e-10
    ray_cosine[ray_valid] = np.sum(first_rays[ray_valid] * second_rays[ray_valid], axis=1) / ray_denominator[ray_valid]
    parallax = np.degrees(np.arccos(np.clip(ray_cosine, -1, 1)))

    return (
        finite
        & (first_depth > 0.03)
        & (second_depth > 0.03)
        & (parallax >= minimum_parallax_degrees)
        & (np.max(pair_errors, axis=1) <= maximum_error_pixels)
        & (np.median(pair_errors, axis=1) <= maximum_median_error_pixels)
    )


@dataclass(frozen=True)
class PnPResult:
    map_from_camera: np.ndarray
    inlier_indices: np.ndarray
    residuals_pixels: np.ndarray


def solve_metric_pnp(
    image_points: np.ndarray,
    map_points: np.ndarray,
    intrinsics: np.ndarray,
    *,
    maximum_reprojection_error_pixels: float = 6.0,
    confidence: float = 0.999,
    iterations: int = 2_000,
) -> PnPResult:
    pixels = np.asarray(image_points, dtype=np.float64).reshape((-1, 2))
    points = np.asarray(map_points, dtype=np.float64).reshape((-1, 3))
    if len(pixels) != len(points) or len(pixels) < 6:
        raise LocalizationError("at least six unique 2D-to-3D correspondences are required")
    success, rotation, translation, inliers = cv2.solvePnPRansac(
        points,
        pixels,
        np.asarray(intrinsics, dtype=np.float64),
        None,
        flags=cv2.SOLVEPNP_AP3P,
        iterationsCount=iterations,
        reprojectionError=maximum_reprojection_error_pixels,
        confidence=confidence,
    )
    if not success or inliers is None or len(inliers) < 6:
        raise LocalizationError("RANSAC PnP did not find a geometrically supported pose")
    inlier_indices = inliers.reshape(-1)
    rotation, translation = cv2.solvePnPRefineLM(
        points[inlier_indices],
        pixels[inlier_indices],
        np.asarray(intrinsics, dtype=np.float64),
        None,
        rotation,
        translation,
    )
    map_from_camera = map_from_ar_camera_from_cv_pose(rotation, translation)
    projected, depth = project_map_points(points[inlier_indices], intrinsics, map_from_camera)
    residuals = np.linalg.norm(projected - pixels[inlier_indices], axis=1)
    finite = np.isfinite(residuals) & (depth > 0.03) & (residuals <= maximum_reprojection_error_pixels)
    inlier_indices = inlier_indices[finite]
    residuals = residuals[finite]
    if len(inlier_indices) < 6:
        raise LocalizationError("refined PnP pose lost geometric support")
    return PnPResult(map_from_camera, inlier_indices, residuals.astype(np.float32))


def pose_delta(first: np.ndarray, second: np.ndarray) -> tuple[float, float]:
    validate_rigid_transform(first)
    validate_rigid_transform(second)
    translation = float(np.linalg.norm(first[:3, 3] - second[:3, 3]))
    relative = first[:3, :3].T @ second[:3, :3]
    cosine = float(np.clip((np.trace(relative) - 1) / 2, -1, 1))
    return translation, math.acos(cosine)
