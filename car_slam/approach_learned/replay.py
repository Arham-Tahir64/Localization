from __future__ import annotations

import cv2
import numpy as np

from .pipeline import FrameInput


def generated_replay(count: int = 48, seed: int = 20260812) -> list[FrameInput]:
    """Deterministic textured drive with blur, blackout and a revisited place."""
    rng = np.random.default_rng(seed)
    world = rng.integers(0, 70, (360, 1800, 3), dtype=np.uint8)
    for _ in range(500):
        x, y = rng.integers(5, 1795), rng.integers(5, 355)
        cv2.circle(world, (int(x), int(y)), int(rng.integers(2, 10)), tuple(int(v) for v in rng.integers(90, 255, 3)), -1)
    frames = []
    positions = list(range(0, 24 * 8, 8)) + list(range(23 * 8, -1, -8))
    for i, x in enumerate(positions[:count]):
        image = world[:, x:x + 640].copy()
        if i in (12, 13):
            image = cv2.GaussianBlur(image, (21, 21), 8)
        if i == 14:
            image[:] = 5
        frames.append(FrameInput(f"generated-{i:04d}", image, i / 20.0, (x * 0.035, 0.0, 0.0)))
    return frames
