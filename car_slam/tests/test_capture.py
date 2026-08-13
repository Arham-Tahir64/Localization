import json

import cv2
import numpy as np

from car_slam.common.capture import _capture_source, load_calibration, record_sequence
from car_slam.common.dataset import load_sequence


def test_capture_source_distinguishes_indices_from_urls():
    assert _capture_source("0") == 0
    assert _capture_source("12") == 12
    assert _capture_source("rtsp://camera.local/live") == "rtsp://camera.local/live"


def test_records_video_into_neutral_sequence(tmp_path):
    width, height = 96, 64
    video_path = tmp_path / "input.avi"
    writer = cv2.VideoWriter(
        str(video_path), cv2.VideoWriter_fourcc(*"MJPG"), 10, (width, height)
    )
    assert writer.isOpened()
    for index in range(6):
        frame = np.full((height, width, 3), index * 20, dtype=np.uint8)
        writer.write(frame)
    writer.release()
    calibration_path = tmp_path / "calibration.json"
    calibration_path.write_text(json.dumps({
        "width": width,
        "height": height,
        "intrinsics": [[80, 0, width / 2], [0, 80, height / 2], [0, 0, 1]],
        "distortion": [],
    }))
    calibration = load_calibration(calibration_path)
    manifest = record_sequence(
        str(video_path),
        tmp_path / "recording",
        calibration,
        name="test-drive",
        maximum_frames=5,
        frame_stride=1,
        jpeg_quality=95,
    )
    sequence = load_sequence(manifest)
    assert sequence.name == "test-drive"
    assert len(sequence.frames) == 5
    assert all(frame.world_from_camera is None for frame in sequence.frames)
