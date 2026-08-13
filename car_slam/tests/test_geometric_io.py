import json

import cv2
import numpy as np

from car_slam.approach_geometric.io import load_manifest


def test_neutral_manifest_round_trip(tmp_path):
    image = np.zeros((48, 64, 3), np.uint8)
    assert cv2.imwrite(str(tmp_path / "000.jpg"), image)
    manifest = {"intrinsics": [[50, 0, 32], [0, 50, 24], [0, 0, 1]], "frames": [
        {"id": 4, "timestamp": 1.25, "image": "000.jpg", "pose": np.eye(4).tolist()}]}
    path = tmp_path / "manifest.json"; path.write_text(json.dumps(manifest))
    frame = list(load_manifest(path))[0]
    assert frame.frame_id == 4
    assert frame.image.shape == (48, 64, 3)
    np.testing.assert_allclose(frame.ground_truth, np.eye(4))
