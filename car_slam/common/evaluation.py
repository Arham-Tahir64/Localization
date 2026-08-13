from __future__ import annotations

import json
import math
from pathlib import Path
from statistics import median
from typing import Any

import numpy as np

from .dataset import SlamSequence, load_sequence


def _similarity_alignment(estimated: np.ndarray, reference: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    estimated_mean = estimated.mean(axis=0)
    reference_mean = reference.mean(axis=0)
    estimated_centered = estimated - estimated_mean
    reference_centered = reference - reference_mean
    covariance = reference_centered.T @ estimated_centered / len(estimated)
    left, singular_values, right_transpose = np.linalg.svd(covariance)
    sign = np.ones(3)
    if np.linalg.det(left @ right_transpose) < 0:
        sign[-1] = -1
    rotation = left @ np.diag(sign) @ right_transpose
    variance = float(np.sum(estimated_centered**2) / len(estimated))
    scale = float(np.sum(singular_values * sign) / max(variance, 1e-12))
    translation = reference_mean - scale * (rotation @ estimated_mean)
    return scale, rotation, translation


def _rotation_error_degrees(first: np.ndarray, second: np.ndarray) -> float:
    delta = first.T @ second
    cosine = np.clip((np.trace(delta) - 1) / 2, -1, 1)
    return math.degrees(math.acos(float(cosine)))


def _pose(value: object) -> np.ndarray | None:
    if value is None:
        return None
    matrix = np.asarray(value, dtype=np.float64)
    if matrix.shape != (4, 4) or not np.all(np.isfinite(matrix)):
        return None
    rotation = matrix[:3, :3]
    if not np.allclose(matrix[3], [0, 0, 0, 1], atol=1e-4):
        return None
    if not np.allclose(rotation.T @ rotation, np.eye(3), atol=0.03) or np.linalg.det(rotation) <= 0:
        return None
    return matrix


def evaluate_run(sequence: SlamSequence | str | Path, result: dict[str, Any] | str | Path) -> dict[str, Any]:
    if not isinstance(sequence, SlamSequence):
        sequence = load_sequence(sequence)
    if isinstance(result, (str, Path)):
        result = json.loads(Path(result).read_text())
    if result.get("schemaVersion") != 1 or result.get("sequence") != sequence.name:
        raise ValueError("result schema or sequence identity mismatch")
    records = result.get("frames", [])
    if len(records) != len(sequence.frames):
        raise ValueError("result must contain exactly one record per input frame")

    valid_indices: list[int] = []
    estimated_poses: list[np.ndarray] = []
    reference_poses: list[np.ndarray] = []
    latencies: list[float] = []
    tracked_features: list[int] = []
    inliers: list[int] = []
    recovery_frames: list[int] = []
    loss_start: int | None = None
    previous_valid = False
    successful_frames = 0

    for index, (frame, record) in enumerate(zip(sequence.frames, records)):
        if int(record.get("index", -1)) != index:
            raise ValueError("result frame indices are not contiguous")
        latency = float(record.get("latencyMilliseconds", np.nan))
        if np.isfinite(latency) and latency >= 0:
            latencies.append(latency)
        tracked_features.append(max(0, int(record.get("trackedFeatures", 0))))
        inliers.append(max(0, int(record.get("inliers", 0))))
        estimate = _pose(record.get("worldFromCameraCV"))
        is_valid = estimate is not None and record.get("status") in ("tracking", "relocalized")
        if is_valid:
            successful_frames += 1
        if not is_valid and previous_valid and loss_start is None:
            loss_start = index
        if is_valid and loss_start is not None:
            recovery_frames.append(index - loss_start)
            loss_start = None
        previous_valid = is_valid
        if is_valid and frame.world_from_camera is not None:
            valid_indices.append(index)
            estimated_poses.append(estimate)
            reference_poses.append(frame.world_from_camera)

    trajectory: dict[str, Any] = {
        "groundTruthFrames": sum(frame.world_from_camera is not None for frame in sequence.frames),
        "evaluatedFrames": len(valid_indices),
    }
    if len(estimated_poses) >= 3:
        estimated = np.stack(estimated_poses)
        reference = np.stack(reference_poses)
        scale, alignment_rotation, alignment_translation = _similarity_alignment(
            estimated[:, :3, 3], reference[:, :3, 3]
        )
        aligned = estimated.copy()
        aligned[:, :3, 3] = (
            scale * (alignment_rotation @ estimated[:, :3, 3].T)
        ).T + alignment_translation
        aligned[:, :3, :3] = alignment_rotation[None] @ estimated[:, :3, :3]
        translation_errors = np.linalg.norm(aligned[:, :3, 3] - reference[:, :3, 3], axis=1)
        rotation_errors = np.asarray([
            _rotation_error_degrees(a[:3, :3], b[:3, :3])
            for a, b in zip(aligned, reference)
        ])
        rpe_translation: list[float] = []
        rpe_rotation: list[float] = []
        for first in range(len(aligned) - 1):
            expected = np.linalg.inv(reference[first]) @ reference[first + 1]
            observed = np.linalg.inv(aligned[first]) @ aligned[first + 1]
            error = np.linalg.inv(expected) @ observed
            rpe_translation.append(float(np.linalg.norm(error[:3, 3])))
            rpe_rotation.append(_rotation_error_degrees(np.eye(3), error[:3, :3]))
        reference_steps = np.linalg.norm(np.diff(reference[:, :3, 3], axis=0), axis=1)
        path_length = float(np.sum(reference_steps))
        endpoint_vector_error = (
            (aligned[-1, :3, 3] - aligned[0, :3, 3])
            - (reference[-1, :3, 3] - reference[0, :3, 3])
        )
        trajectory.update({
            "sim3Scale": scale,
            "ateRmseMeters": float(np.sqrt(np.mean(translation_errors**2))),
            "ateMedianMeters": float(np.median(translation_errors)),
            "rotationMedianDegrees": float(np.median(rotation_errors)),
            "rpeTranslationRmseMeters": float(np.sqrt(np.mean(np.square(rpe_translation)))) if rpe_translation else None,
            "rpeRotationRmseDegrees": float(np.sqrt(np.mean(np.square(rpe_rotation)))) if rpe_rotation else None,
            "pathLengthMeters": path_length,
            "endpointDriftPercent": float(100 * np.linalg.norm(endpoint_vector_error) / max(path_length, 1e-9)),
        })

    latency_ordered = sorted(latencies)
    p95_index = max(0, math.ceil(0.95 * len(latency_ordered)) - 1) if latency_ordered else 0
    resources = result.get("resources", {})
    return {
        "schemaVersion": 1,
        "approach": result.get("approach", "unknown"),
        "sequence": sequence.name,
        "frames": len(sequence.frames),
        "tracking": {
            "successfulFrames": successful_frames,
            "successRate": successful_frames / len(sequence.frames),
            "lossEvents": len(recovery_frames) + (1 if loss_start is not None else 0),
            "successfulRecoveries": len(recovery_frames),
            "medianRecoveryFrames": float(median(recovery_frames)) if recovery_frames else None,
        },
        "trajectory": trajectory,
        "features": {
            "medianTracked": float(median(tracked_features)),
            "medianInliers": float(median(inliers)),
            "finalMapPoints": int(records[-1].get("mapPoints", 0)),
            "medianMapReprojectionErrorPixels": result.get("map", {}).get("medianReprojectionErrorPixels"),
        },
        "performance": {
            "medianLatencyMilliseconds": float(median(latencies)) if latencies else None,
            "p95LatencyMilliseconds": float(latency_ordered[p95_index]) if latencies else None,
            "effectiveFps": float(1000 / median(latencies)) if latencies and median(latencies) > 0 else None,
            "cpuSeconds": resources.get("cpuSeconds"),
            "peakRssBytes": resources.get("peakRssBytes"),
        },
        "conditions": _condition_breakdown(sequence, records),
    }


def _condition_breakdown(sequence: SlamSequence, records: list[dict[str, Any]]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for condition in sorted({frame.condition for frame in sequence.frames}):
        indices = [frame.index for frame in sequence.frames if frame.condition == condition]
        successful = sum(
            _pose(records[index].get("worldFromCameraCV")) is not None
            and records[index].get("status") in ("tracking", "relocalized")
            for index in indices
        )
        output[condition] = {"frames": len(indices), "successful": successful, "successRate": successful / len(indices)}
    return output
