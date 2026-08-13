import numpy as np

from car_slam.approach_learned.pipeline import LearnedSLAMConfig, run_replay
from car_slam.approach_learned.pipeline import run_sequence
from car_slam.approach_learned.replay import generated_replay
from car_slam.common.dataset import load_sequence
from car_slam.common.evaluation import evaluate_run
from car_slam.common.synthetic_sequence import generate_sequence
from server.housemapper_server.features import SIFTBaselineBackend


def test_generated_replay_is_deterministic_and_reports_contract():
    config = LearnedSLAMConfig(minimum_matches=8, minimum_inliers=6, loop_similarity=0.75)
    first = run_replay(generated_replay(20), SIFTBaselineBackend(400), config)
    second = run_replay(generated_replay(20), SIFTBaselineBackend(400), config)
    assert np.allclose(first.trajectory, second.trajectory)
    required = {"trackingSuccessRate", "ateRMSE", "rpeRMSE", "driftPercent", "mapPoints",
                "mapQuality", "meanTrackedFeatures", "meanInliers", "fps", "meanLatencyMs",
                "p95LatencyMs", "rssMB", "cpuSeconds", "failures", "recoveries"}
    assert required <= first.metrics.keys()
    assert first.metrics["frames"] == 20
    assert first.metrics["keyframes"] <= config.max_keyframes


def test_bad_frames_are_explicit_failures_not_stream_crashes():
    frames = generated_replay(4)
    frames[1] = type(frames[1])(frames[1].frame_id, np.zeros_like(frames[1].image), frames[1].timestamp, frames[1].ground_truth_xyz)
    result = run_replay(frames, SIFTBaselineBackend(300), LearnedSLAMConfig(minimum_matches=8, minimum_inliers=6))
    assert result.metrics["frames"] == 4
    assert result.metrics["failures"] >= 1


def test_common_sequence_result_passes_neutral_evaluator(tmp_path):
    sequence = load_sequence(generate_sequence(tmp_path / "common", frames=12))
    result = run_sequence(sequence, SIFTBaselineBackend(400),
                          LearnedSLAMConfig(minimum_matches=8, minimum_inliers=6))
    assert {row["status"] for row in result["frames"]} <= {"tracking", "relocalized", "lost"}
    assert all(row["worldFromCameraCV"] is None or np.asarray(row["worldFromCameraCV"]).shape == (4, 4)
               for row in result["frames"])
    evaluation = evaluate_run(sequence, result)
    assert evaluation["approach"] == "appearance-learned-map-first"
    assert evaluation["frames"] == 12
