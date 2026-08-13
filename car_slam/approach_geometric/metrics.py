from __future__ import annotations

import numpy as np


def trajectory_metrics(estimated: list[np.ndarray], truth: list[np.ndarray]) -> dict[str, float | None]:
    """Sim(3)-aligned monocular ATE and scale-invariant relative translation error."""
    if len(estimated) < 3 or len(estimated) != len(truth):
        return {"ate_rmse_m": None, "rpe_translation_m": None, "drift_percent": None}
    x = np.asarray([p[:3, 3] for p in estimated]); y = np.asarray([p[:3, 3] for p in truth])
    xc, yc = x - x.mean(0), y - y.mean(0)
    u, _, vt = np.linalg.svd(xc.T @ yc)
    rotation = u @ np.diag([1., 1., np.linalg.det(u @ vt)]) @ vt
    scale = float(np.sum((xc @ rotation) * yc) / max(np.sum(xc * xc), 1e-12))
    aligned = scale * xc @ rotation + y.mean(0)
    ate = float(np.sqrt(np.mean(np.sum((aligned - y) ** 2, axis=1))))
    de, dg = np.diff(aligned, axis=0), np.diff(y, axis=0)
    rpe = float(np.sqrt(np.mean(np.sum((de - dg) ** 2, axis=1))))
    path = float(np.linalg.norm(np.diff(y, axis=0), axis=1).sum())
    drift = float(100 * np.linalg.norm((aligned[-1] - aligned[0]) - (y[-1] - y[0])) / max(path, 1e-9))
    return {"ate_rmse_m": ate, "rpe_translation_m": rpe, "drift_percent": drift}
