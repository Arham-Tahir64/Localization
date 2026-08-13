from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def calibrate_camera(
    image_paths: list[Path],
    *,
    columns: int,
    rows: int,
    square_size: float,
) -> dict[str, object]:
    if columns < 3 or rows < 3 or square_size <= 0:
        raise ValueError("checkerboard dimensions and square size must be positive")
    object_template = np.zeros((rows * columns, 3), np.float32)
    object_template[:, :2] = np.mgrid[0:columns, 0:rows].T.reshape(-1, 2) * square_size
    object_points: list[np.ndarray] = []
    image_points: list[np.ndarray] = []
    image_size: tuple[int, int] | None = None
    rejected: list[str] = []
    for path in image_paths:
        image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if image is None:
            rejected.append(str(path))
            continue
        current_size = (image.shape[1], image.shape[0])
        if image_size is not None and current_size != image_size:
            raise ValueError("all calibration images must use the same resolution")
        image_size = current_size
        found, corners = cv2.findChessboardCornersSB(
            image,
            (columns, rows),
            flags=cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY,
        )
        if not found:
            rejected.append(str(path))
            continue
        object_points.append(object_template.copy())
        image_points.append(corners.astype(np.float32))
    if image_size is None or len(object_points) < 8:
        raise ValueError("at least eight same-resolution images must contain the complete checkerboard")
    rms, intrinsics, distortion, _, _ = cv2.calibrateCamera(
        object_points, image_points, image_size, None, None
    )
    if not np.isfinite(rms) or not np.all(np.isfinite(intrinsics)):
        raise RuntimeError("camera calibration produced invalid values")
    return {
        "schemaVersion": 1,
        "width": image_size[0],
        "height": image_size[1],
        "intrinsics": intrinsics.tolist(),
        "distortion": distortion.reshape(-1).tolist(),
        "rmsReprojectionErrorPixels": float(rms),
        "acceptedImages": len(object_points),
        "rejectedImages": rejected,
        "checkerboard": {"innerColumns": columns, "innerRows": rows, "squareSize": square_size},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Calibrate the fixed car camera from checkerboard photos")
    parser.add_argument("images", type=Path, help="directory containing calibration images")
    parser.add_argument("--columns", type=int, required=True, help="checkerboard inner-corner columns")
    parser.add_argument("--rows", type=int, required=True, help="checkerboard inner-corner rows")
    parser.add_argument("--square-size", type=float, required=True, help="physical square size in any consistent unit")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    paths = sorted(
        path for path in arguments.images.iterdir()
        if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff"}
    )
    result = calibrate_camera(
        paths,
        columns=arguments.columns,
        rows=arguments.rows,
        square_size=arguments.square_size,
    )
    arguments.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: result[key] for key in ("acceptedImages", "rmsReprojectionErrorPixels")}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
