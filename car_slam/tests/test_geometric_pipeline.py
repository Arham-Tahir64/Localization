import json

from car_slam.approach_geometric.cli import main
from car_slam.approach_geometric.pipeline import GeometricSLAM, SLAMConfig, run_sequence
from car_slam.approach_geometric.replay import generated_replay
from car_slam.common.dataset import load_sequence
from car_slam.common.evaluation import evaluate_run
from car_slam.common.synthetic_sequence import generate_sequence


def test_generated_replay_is_deterministic():
    a, b = list(generated_replay(3)), list(generated_replay(3))
    assert all((x.image == y.image).all() for x, y in zip(a, b))


def test_pipeline_tracks_and_recovers_after_quality_dropout():
    slam = GeometricSLAM(SLAMConfig(min_tracks=18, min_inliers=10, keyframe_gap=5))
    for frame in generated_replay(48, width=480, height=270):
        slam.process(frame)
    summary = slam.summary()
    assert summary["tracking_success_rate"] > .75
    assert summary["failures"] >= 1
    assert summary["recoveries"] >= 1
    assert summary["keyframes"] >= 2
    assert summary["ate_rmse_m"] is not None


def test_cli_emits_consistent_json(tmp_path, capsys):
    output = tmp_path / "metrics.json"
    result = main(["--generated-frames", "12", "--output", str(output)])
    saved = json.loads(output.read_text())
    assert saved["summary"] == result["summary"]
    assert len(saved["frames"]) == 12
    assert "tracking_success_rate" in json.loads(capsys.readouterr().out)


def test_common_sequence_passes_neutral_evaluator(tmp_path):
    sequence = load_sequence(generate_sequence(tmp_path / "common", frames=12))
    result = run_sequence(sequence)
    evaluation = evaluate_run(sequence, result)
    assert evaluation["approach"] == "geometry-first-classical"
    assert evaluation["frames"] == 12
    assert all(row["worldFromCameraCV"] is None or len(row["worldFromCameraCV"]) == 4 for row in result["frames"])


def test_common_adapter_never_passes_ground_truth_into_tracker(tmp_path, monkeypatch):
    sequence = load_sequence(generate_sequence(tmp_path / "common-no-leak", frames=5))
    seen = []
    original = GeometricSLAM.process

    def inspect(self, frame):
        seen.append(frame.ground_truth)
        return original(self, frame)

    monkeypatch.setattr(GeometricSLAM, "process", inspect)
    run_sequence(sequence)
    assert seen == [None] * len(sequence.frames)
