import json
from pathlib import Path

import numpy as np

from car_slam.common.dataset import load_sequence
from car_slam.common.evaluation import evaluate_run
from car_slam.common.synthetic_sequence import generate_sequence


def test_generated_sequence_is_valid_and_labels_degradations(tmp_path: Path) -> None:
    sequence = load_sequence(generate_sequence(tmp_path / "sequence", frames=145))
    assert len(sequence.frames) == 145
    assert sequence.calibration.width == 640
    assert {frame.condition for frame in sequence.frames} >= {
        "nominal", "low_light", "motion_blur", "texture_poor", "occluded"
    }


def test_evaluator_removes_monocular_similarity_and_reports_recovery(tmp_path: Path) -> None:
    sequence = load_sequence(generate_sequence(tmp_path / "sequence", frames=12))
    rotation = np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]], dtype=float)
    translation = np.array([8, -2, 4], dtype=float)
    records = []
    for frame in sequence.frames:
        estimate = frame.world_from_camera.copy()
        estimate[:3, 3] = 2.5 * (rotation @ estimate[:3, 3]) + translation
        estimate[:3, :3] = rotation @ estimate[:3, :3]
        valid = frame.index not in (5, 6)
        records.append({
            "index": frame.index,
            "status": "tracking" if valid else "lost",
            "worldFromCameraCV": estimate.tolist() if valid else None,
            "latencyMilliseconds": 20,
            "trackedFeatures": 100,
            "inliers": 80,
            "mapPoints": frame.index * 10,
        })
    result = {
        "schemaVersion": 1,
        "approach": "fixture",
        "sequence": sequence.name,
        "frames": records,
        "map": {"medianReprojectionErrorPixels": 0.5},
        "resources": {"cpuSeconds": 1.5, "peakRssBytes": 1_000_000},
    }
    report = evaluate_run(sequence, result)
    assert report["trajectory"]["ateRmseMeters"] < 1e-6
    assert report["tracking"]["successfulFrames"] == 10
    assert report["tracking"]["successfulRecoveries"] == 1
    assert report["tracking"]["medianRecoveryFrames"] == 2
    assert report["performance"]["effectiveFps"] == 50


def test_manifest_rejects_non_contiguous_frames(tmp_path: Path) -> None:
    path = generate_sequence(tmp_path / "sequence", frames=4)
    payload = json.loads(path.read_text())
    payload["frames"][2]["index"] = 5
    path.write_text(json.dumps(payload))
    try:
        load_sequence(path)
    except ValueError as error:
        assert "contiguous" in str(error)
    else:
        raise AssertionError("invalid manifest was accepted")
