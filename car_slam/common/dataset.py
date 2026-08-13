from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path

import cv2
import numpy as np


@dataclass(frozen=True)
class CameraCalibration:
    width: int
    height: int
    intrinsics: np.ndarray
    distortion: np.ndarray


@dataclass(frozen=True)
class SequenceFrame:
    index: int
    timestamp: float
    image_path: Path
    condition: str
    world_from_camera: np.ndarray | None

    def image(self) -> np.ndarray:
        decoded = cv2.imread(str(self.image_path), cv2.IMREAD_COLOR)
        if decoded is None:
            raise ValueError(f"could not decode frame image: {self.image_path}")
        return decoded


@dataclass(frozen=True)
class SlamSequence:
    name: str
    fps: float
    calibration: CameraCalibration
    frames: tuple[SequenceFrame, ...]
    root: Path


def _matrix(values: object, rows: int, columns: int, label: str) -> np.ndarray:
    matrix = np.asarray(values, dtype=np.float64)
    if matrix.shape != (rows, columns) or not np.all(np.isfinite(matrix)):
        raise ValueError(f"{label} must be a finite {rows}x{columns} matrix")
    return matrix


def _rigid_transform(values: object) -> np.ndarray:
    transform = _matrix(values, 4, 4, "worldFromCameraCV")
    rotation = transform[:3, :3]
    if not np.allclose(transform[3], [0, 0, 0, 1], atol=1e-6):
        raise ValueError("worldFromCameraCV has an invalid homogeneous row")
    if not np.allclose(rotation.T @ rotation, np.eye(3), atol=2e-3):
        raise ValueError("worldFromCameraCV rotation is not orthonormal")
    if np.linalg.det(rotation) < 0.99:
        raise ValueError("worldFromCameraCV rotation is not right handed")
    return transform


def load_sequence(manifest_path: str | Path) -> SlamSequence:
    path = Path(manifest_path).resolve()
    payload = json.loads(path.read_text())
    if payload.get("schemaVersion") != 1:
        raise ValueError("unsupported car-SLAM sequence schema")
    name = payload.get("name")
    fps = float(payload.get("fps", 0))
    camera = payload.get("camera", {})
    width = int(camera.get("width", 0))
    height = int(camera.get("height", 0))
    if not isinstance(name, str) or not name or fps <= 0 or width <= 0 or height <= 0:
        raise ValueError("sequence name, fps, and camera dimensions are required")
    intrinsics = _matrix(camera.get("intrinsics"), 3, 3, "intrinsics")
    distortion = np.asarray(camera.get("distortion", []), dtype=np.float64).reshape(-1)
    if distortion.size not in (0, 4, 5, 8, 12, 14) or not np.all(np.isfinite(distortion)):
        raise ValueError("distortion must be an OpenCV-compatible finite vector")

    frames: list[SequenceFrame] = []
    previous_timestamp = -np.inf
    for expected_index, record in enumerate(payload.get("frames", [])):
        index = int(record.get("index", -1))
        timestamp = float(record.get("timestamp", np.nan))
        image_path = (path.parent / record.get("image", "")).resolve()
        if index != expected_index or not np.isfinite(timestamp) or timestamp <= previous_timestamp:
            raise ValueError("frames require contiguous indices and increasing timestamps")
        if not image_path.is_file() or path.parent not in image_path.parents:
            raise ValueError(f"frame image escapes or is absent: {image_path}")
        ground_truth = record.get("worldFromCameraCV")
        frames.append(
            SequenceFrame(
                index=index,
                timestamp=timestamp,
                image_path=image_path,
                condition=str(record.get("condition", "nominal")),
                world_from_camera=None if ground_truth is None else _rigid_transform(ground_truth),
            )
        )
        previous_timestamp = timestamp
    if len(frames) < 3:
        raise ValueError("a SLAM sequence requires at least three frames")
    return SlamSequence(
        name=name,
        fps=fps,
        calibration=CameraCalibration(width, height, intrinsics, distortion),
        frames=tuple(frames),
        root=path.parent,
    )
