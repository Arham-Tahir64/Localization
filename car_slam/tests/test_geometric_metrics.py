import numpy as np

from car_slam.approach_geometric.metrics import trajectory_metrics


def _pose(x, z):
    value = np.eye(4); value[:3, 3] = [x, 0, z]; return value


def test_sim3_metrics_remove_monocular_scale_and_offset():
    truth = [_pose(0, i) for i in range(6)]
    estimated = [_pose(10, 3 * i) for i in range(6)]
    result = trajectory_metrics(estimated, truth)
    assert result["ate_rmse_m"] < 1e-9
    assert result["rpe_translation_m"] < 1e-9
    assert result["drift_percent"] < 1e-9
