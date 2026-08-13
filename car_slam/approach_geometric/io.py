from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Iterator

import cv2
import numpy as np

from housemapper_server.geometry import validate_intrinsics, validate_rigid_transform


@dataclass(frozen=True)
class Frame:
    frame_id: int
    timestamp: float
    image: np.ndarray
    intrinsics: np.ndarray
    ground_truth: np.ndarray | None = None


def load_manifest(path: Path) -> Iterator[Frame]:
    """Load neutral JSON manifest. Poses are row-major T_world_camera (AR convention)."""
    root = path.parent
    data = json.loads(path.read_text())
    default_k = np.asarray(data["intrinsics"], dtype=np.float64).reshape(3, 3)
    for index, record in enumerate(data["frames"]):
        image_path = (root / record["image"]).resolve()
        image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError(f"cannot decode frame: {image_path}")
        k = np.asarray(record.get("intrinsics", default_k), dtype=np.float64).reshape(3, 3)
        validate_intrinsics(k, image.shape[1], image.shape[0])
        pose = record.get("pose")
        gt = None if pose is None else np.asarray(pose, dtype=np.float64).reshape(4, 4)
        if gt is not None:
            validate_rigid_transform(gt)
        yield Frame(int(record.get("id", index)), float(record.get("timestamp", index)), image, k, gt)


def load_kitti(sequence: Path, poses: Path | None = None, *, fps: float = 10.0) -> Iterator[Frame]:
    """Load KITTI odometry image_0, calib.txt and optional 3x4 pose rows."""
    calibration = {}
    for line in (sequence / "calib.txt").read_text().splitlines():
        if ":" in line:
            name, values = line.split(":", 1)
            calibration[name] = np.fromstring(values, sep=" ")
    projection = calibration.get("P0")
    if projection is None or projection.size != 12:
        raise ValueError("KITTI calib.txt requires P0")
    k = projection.reshape(3, 4)[:, :3]
    gt_rows = poses.read_text().splitlines() if poses else []
    image_dir = sequence / "image_0"
    files = sorted(image_dir.glob("*.png")) or sorted(image_dir.glob("*.jpg"))
    for index, image_path in enumerate(files):
        image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        if image is None:
            continue
        gt = None
        if index < len(gt_rows):
            cv_pose = np.eye(4); cv_pose[:3] = np.fromstring(gt_rows[index], sep=" ").reshape(3, 4)
            # KITTI camera-to-world uses OpenCV camera axes; expose server AR camera axes.
            gt = cv_pose @ np.diag([1.0, -1.0, -1.0, 1.0])
        yield Frame(index, index / fps, image, k.copy(), gt)
