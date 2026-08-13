from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def _world_from_camera(position: np.ndarray, yaw: float) -> np.ndarray:
    cosine, sine = np.cos(yaw), np.sin(yaw)
    transform = np.eye(4, dtype=np.float64)
    transform[:3, :3] = np.array([
        [cosine, 0, sine],
        [0, 1, 0],
        [-sine, 0, cosine],
    ])
    transform[:3, 3] = position
    return transform


def _landmarks(seed: int) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    roadside = np.column_stack((
        rng.choice([-1, 1], 2_500) * rng.uniform(4, 14, 2_500),
        rng.uniform(-3.5, 3.5, 2_500),
        rng.uniform(-10, 95, 2_500),
    ))
    overhead = np.column_stack((
        rng.uniform(-12, 12, 900),
        rng.uniform(-5.5, -2.5, 900),
        rng.uniform(-5, 95, 900),
    ))
    points = np.vstack((roadside, overhead)).astype(np.float64)
    patterns = rng.integers(0, 2, (len(points), 5, 5), dtype=np.uint8) * 210 + 35
    return points, patterns


def _render(
    points: np.ndarray,
    patterns: np.ndarray,
    world_from_camera: np.ndarray,
    intrinsics: np.ndarray,
    width: int,
    height: int,
) -> np.ndarray:
    camera_from_world = np.linalg.inv(world_from_camera)
    camera_points = (camera_from_world[:3, :3] @ points.T + camera_from_world[:3, 3:4]).T
    depth = camera_points[:, 2]
    pixels_h = (intrinsics @ camera_points.T).T
    pixels = pixels_h[:, :2] / np.maximum(pixels_h[:, 2:3], 1e-9)
    visible = np.flatnonzero(
        (depth > 2)
        & (depth < 48)
        & (pixels[:, 0] >= 4)
        & (pixels[:, 0] < width - 4)
        & (pixels[:, 1] >= 4)
        & (pixels[:, 1] < height - 4)
    )
    image = np.full((height, width), 24, dtype=np.uint8)
    image[:] = np.linspace(40, 16, height, dtype=np.uint8)[:, None]
    for index in visible[np.argsort(depth[visible])[::-1]]:
        x, y = np.rint(pixels[index]).astype(int)
        size = int(np.clip(42 / depth[index], 1, 4))
        patch = cv2.resize(patterns[index], (size * 5, size * 5), interpolation=cv2.INTER_NEAREST)
        half = patch.shape[0] // 2
        y0, x0 = y - half, x - half
        y1, x1 = y0 + patch.shape[0], x0 + patch.shape[1]
        if y0 >= 0 and x0 >= 0 and y1 <= height and x1 <= width:
            image[y0:y1, x0:x1] = np.maximum(image[y0:y1, x0:x1], patch)
    cv2.line(image, (width // 2 - 35, height), (width // 2 - 8, height // 2), 125, 2)
    cv2.line(image, (width // 2 + 35, height), (width // 2 + 8, height // 2), 125, 2)
    return cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)


def generate_sequence(destination: str | Path, *, frames: int = 180, seed: int = 20260812) -> Path:
    root = Path(destination).resolve()
    image_root = root / "images"
    image_root.mkdir(parents=True, exist_ok=True)
    width, height, fps = 640, 360, 30.0
    intrinsics = np.array([[520, 0, width / 2], [0, 520, height / 2], [0, 0, 1]], dtype=np.float64)
    points, patterns = _landmarks(seed)
    rng = np.random.default_rng(seed + 1)
    records = []
    for index in range(frames):
        progress = index / max(frames - 1, 1)
        z = progress * 70
        x = 2.6 * np.sin(progress * np.pi * 1.6)
        yaw = 0.075 * np.sin(progress * np.pi * 1.6)
        pose = _world_from_camera(np.array([x, 0, z]), yaw)
        image = _render(points, patterns, pose, intrinsics, width, height)
        condition = "nominal"
        if 38 <= index < 55:
            condition = "low_light"
            image = cv2.convertScaleAbs(image, alpha=0.28, beta=-4)
        elif 72 <= index < 88:
            condition = "motion_blur"
            kernel = np.zeros((1, 17), dtype=np.float32)
            kernel[0] = 1 / kernel.size
            image = cv2.filter2D(image, -1, kernel)
        elif 108 <= index < 122:
            condition = "texture_poor"
            image[:, : int(width * 0.78)] = cv2.GaussianBlur(
                image[:, : int(width * 0.78)], (31, 31), 0
            )
        elif 136 <= index < 142:
            condition = "occluded"
            image[:] = rng.integers(8, 18, image.shape, dtype=np.uint8)
        noise = rng.normal(0, 2.2, image.shape).astype(np.int16)
        image = np.clip(image.astype(np.int16) + noise, 0, 255).astype(np.uint8)
        image_name = f"{index:06d}.png"
        if not cv2.imwrite(str(image_root / image_name), image):
            raise RuntimeError("could not write synthetic benchmark frame")
        records.append({
            "index": index,
            "timestamp": index / fps,
            "image": f"images/{image_name}",
            "condition": condition,
            "worldFromCameraCV": pose.tolist(),
        })
    manifest = {
        "schemaVersion": 1,
        "name": "deterministic-car-geometry-v1",
        "fps": fps,
        "frameConvention": "T_world_camera_cv-right-handed-x-right-y-down-z-forward-meters",
        "camera": {
            "width": width,
            "height": height,
            "intrinsics": intrinsics.tolist(),
            "distortion": [],
        },
        "frames": records,
        "limitations": "Procedural static geometry for regression and equal conditions; not physical driving evidence.",
    }
    manifest_path = root / "sequence.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True))
    return manifest_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination")
    parser.add_argument("--frames", type=int, default=180)
    arguments = parser.parse_args()
    print(generate_sequence(arguments.destination, frames=arguments.frames))


if __name__ == "__main__":
    main()
