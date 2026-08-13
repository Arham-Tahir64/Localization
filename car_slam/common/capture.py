from __future__ import annotations

import argparse
import json
from pathlib import Path
from time import monotonic

import cv2
import numpy as np

from .dataset import CameraCalibration


def load_calibration(path: Path) -> CameraCalibration:
    payload = json.loads(path.read_text())
    width, height = int(payload.get("width", 0)), int(payload.get("height", 0))
    intrinsics = np.asarray(payload.get("intrinsics"), dtype=np.float64)
    distortion = np.asarray(payload.get("distortion", []), dtype=np.float64).reshape(-1)
    if width <= 0 or height <= 0 or intrinsics.shape != (3, 3):
        raise ValueError("calibration requires width, height, and a 3x3 intrinsics matrix")
    if not np.all(np.isfinite(intrinsics)) or not np.all(np.isfinite(distortion)):
        raise ValueError("calibration values must be finite")
    if distortion.size not in (0, 4, 5, 8, 12, 14):
        raise ValueError("distortion must be an OpenCV-compatible vector")
    return CameraCalibration(width, height, intrinsics, distortion)


def _capture_source(value: str) -> int | str:
    return int(value) if value.isdecimal() else value


def record_sequence(
    source: int | str,
    destination: Path,
    calibration: CameraCalibration,
    *,
    name: str,
    maximum_frames: int | None,
    frame_stride: int,
    jpeg_quality: int,
) -> Path:
    if frame_stride < 1 or maximum_frames is not None and maximum_frames < 3:
        raise ValueError("frame stride must be positive and maximum frames must be at least three")
    destination = destination.resolve()
    image_root = destination / "images"
    image_root.mkdir(parents=True, exist_ok=True)
    capture = cv2.VideoCapture(source)
    if not capture.isOpened():
        raise RuntimeError(f"could not open camera/video source: {source}")
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, calibration.width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, calibration.height)
    nominal_fps = float(capture.get(cv2.CAP_PROP_FPS))
    fps = nominal_fps if np.isfinite(nominal_fps) and nominal_fps > 0 else 30.0
    started = monotonic()
    records: list[dict[str, object]] = []
    source_index = 0
    previous_timestamp = -1.0
    try:
        while maximum_frames is None or len(records) < maximum_frames:
            ok, frame = capture.read()
            if not ok:
                break
            if source_index % frame_stride:
                source_index += 1
                continue
            source_index += 1
            height, width = frame.shape[:2]
            if (width, height) != (calibration.width, calibration.height):
                raise RuntimeError(
                    f"source is {width}x{height}, but calibration is "
                    f"{calibration.width}x{calibration.height}; recalibrate at the capture resolution"
                )
            stream_milliseconds = float(capture.get(cv2.CAP_PROP_POS_MSEC))
            timestamp = stream_milliseconds / 1000 if stream_milliseconds > 0 else monotonic() - started
            if timestamp <= previous_timestamp:
                timestamp = previous_timestamp + frame_stride / fps
            filename = f"{len(records):06d}.jpg"
            if not cv2.imwrite(
                str(image_root / filename),
                frame,
                [cv2.IMWRITE_JPEG_QUALITY, jpeg_quality],
            ):
                raise RuntimeError(f"could not write captured frame {filename}")
            records.append({
                "index": len(records),
                "timestamp": timestamp,
                "image": f"images/{filename}",
                "condition": "unlabeled",
                "worldFromCameraCV": None,
            })
            previous_timestamp = timestamp
    finally:
        capture.release()
    if len(records) < 3:
        raise RuntimeError("capture ended before three usable frames were recorded")
    effective_fps = 1 / np.median(np.diff([float(record["timestamp"]) for record in records]))
    manifest = {
        "schemaVersion": 1,
        "name": name,
        "fps": float(effective_fps),
        "frameConvention": "T_world_camera_cv-right-handed-x-right-y-down-z-forward-meters",
        "camera": {
            "width": calibration.width,
            "height": calibration.height,
            "intrinsics": calibration.intrinsics.tolist(),
            "distortion": calibration.distortion.tolist(),
        },
        "frames": records,
        "limitations": "No ground truth. Use for replay and qualitative road testing, not trajectory accuracy scoring.",
    }
    manifest_path = destination / "sequence.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Record a calibrated USB, RTSP, HTTP, or video source")
    parser.add_argument("source", help="camera index such as 0, video path, RTSP URL, or HTTP URL")
    parser.add_argument("destination", type=Path)
    parser.add_argument("--calibration", type=Path, required=True)
    parser.add_argument("--name", default="windshield-capture")
    parser.add_argument("--frames", type=int)
    parser.add_argument("--stride", type=int, default=1)
    parser.add_argument("--jpeg-quality", type=int, choices=range(80, 101), default=95)
    arguments = parser.parse_args(argv)
    manifest = record_sequence(
        _capture_source(arguments.source),
        arguments.destination,
        load_calibration(arguments.calibration),
        name=arguments.name,
        maximum_frames=arguments.frames,
        frame_stride=arguments.stride,
        jpeg_quality=arguments.jpeg_quality,
    )
    print(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
