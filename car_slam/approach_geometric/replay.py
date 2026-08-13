from __future__ import annotations

import cv2
import numpy as np

from .io import Frame


def generated_replay(count: int = 90, width: int = 640, height: int = 360, seed: int = 7):
    """Deterministic textured static-world proxy with metric ground truth."""
    rng = np.random.default_rng(seed)
    k = np.array([[520., 0., width / 2], [0., 520., height / 2], [0., 0., 1.]])
    points = np.column_stack((rng.uniform(-12, 12, 3000), rng.uniform(-3, 3, 3000), rng.uniform(6, 45, 3000)))
    tones = rng.integers(80, 256, len(points))
    for i in range(count):
        # Deliberately visible inter-frame baseline: this is a geometry test, not
        # a codec test, and essential-matrix translation is ill-conditioned at
        # sub-pixel displacement.
        center = np.array([0.055 * np.sin(i / 14), 0., 0.15 * i])
        yaw = 0.012 * np.sin(i / 18)
        r_cw = np.array([[np.cos(yaw), 0., -np.sin(yaw)], [0., 1., 0.], [np.sin(yaw), 0., np.cos(yaw)]])
        camera = (r_cw @ (points - center).T).T
        uv = (k @ camera.T).T
        uv = uv[:, :2] / uv[:, 2:3]
        valid = (camera[:, 2] > .1) & (uv[:, 0] >= 3) & (uv[:, 0] < width - 3) & (uv[:, 1] >= 3) & (uv[:, 1] < height - 3)
        image = np.full((height, width), 24, np.uint8)
        for (x, y), tone in zip(uv[valid].astype(int), tones[valid]):
            cv2.drawMarker(image, (x, y), int(tone), cv2.MARKER_CROSS, 5, 1)
        image = cv2.GaussianBlur(image, (3, 3), .45)
        if i in (36, 37):  # deterministic exposure dropout exercises recovery.
            image[:] = 20
        pose_cv = np.eye(4); pose_cv[:3, :3] = r_cw.T; pose_cv[:3, 3] = center
        pose_ar = pose_cv @ np.diag([1., -1., -1., 1.])
        yield Frame(i, i / 15., cv2.cvtColor(image, cv2.COLOR_GRAY2BGR), k.copy(), pose_ar)
