from __future__ import annotations

import numpy as np

from car_slam.common.dataset import load_sequence
from car_slam.common.evaluation import evaluate_run
from car_slam.common.synthetic_sequence import generate_sequence
from car_slam.hybrid.pipeline import AppearanceProposal, HybridConfig, SequentialHybridSLAM, run_sequence
from server.housemapper_server.features import SIFTBaselineBackend


def test_hybrid_emits_common_contract_and_bounds_appearance_map(tmp_path):
    sequence = load_sequence(generate_sequence(tmp_path / "sequence", frames=24))
    config = HybridConfig(appearance_keyframe_gap=4, maximum_appearance_keyframes=3)
    result = run_sequence(sequence, SIFTBaselineBackend(300), config)
    evaluation = evaluate_run(sequence, result)
    assert len(result["frames"]) == 24
    assert result["map"]["appearanceKeyframes"] <= 3
    assert {row["status"] for row in result["frames"]} <= {"tracking", "relocalized", "lost"}
    assert all(row["worldFromCameraCV"] is None or np.asarray(row["worldFromCameraCV"]).shape == (4, 4)
               for row in result["frames"])
    assert evaluation["sequence"] == "deterministic-car-geometry-v1"


def test_unverified_appearance_candidate_cannot_replace_geometric_pose(tmp_path):
    sequence = load_sequence(generate_sequence(tmp_path / "sequence", frames=16))
    config = HybridConfig(appearance_keyframe_gap=2, minimum_verified_inliers=10_000)
    result = run_sequence(sequence, SIFTBaselineBackend(250), config)
    assert result["geometricallyVerifiedCandidates"] == 0
    assert all(row["status"] != "relocalized" for row in result["frames"])


def test_verified_essential_candidate_cannot_install_unscaled_translation(tmp_path, monkeypatch):
    sequence = load_sequence(generate_sequence(tmp_path / "sequence", frames=3))
    hybrid = SequentialHybridSLAM(SIFTBaselineBackend(200))
    hybrid.appearance_map.append({"index": -20})  # enable recovery path; retrieval itself is controlled below
    authoritative = np.eye(4)
    authoritative[0, 3] = 4.25
    hybrid.geometric.pose_cv = authoritative.copy()

    def lost_geometry(_frame):
        return {"tracking_success": False, "tracked_features": 0, "inliers": 0}

    def verified_but_unscaled(*_args):
        hybrid.verified_candidates += 1
        return AppearanceProposal(True, 80, 70, np.eye(3), np.array([1.0, 0.0, 0.0]))

    monkeypatch.setattr(hybrid.geometric, "process", lost_geometry)
    monkeypatch.setattr(hybrid, "_recover", verified_but_unscaled)
    record = hybrid.process(sequence.frames[0], sequence.calibration)
    assert hybrid.verified_candidates == 1
    assert record["status"] == "lost"
    assert record["worldFromCameraCV"] is None
    assert np.array_equal(hybrid.geometric.pose_cv, authoritative)
