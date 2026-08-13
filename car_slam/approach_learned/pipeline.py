from __future__ import annotations

from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path
from time import perf_counter
from typing import Iterable, Protocol
import json
import math
import os
import resource

import cv2
import numpy as np


class FeatureBackend(Protocol):
    def extract(self, image_bgr: np.ndarray): ...
    def match(self, first, second): ...


@dataclass(frozen=True)
class LearnedSLAMConfig:
    max_keyframes: int = 80
    submap_size: int = 12
    keyframe_translation_px: float = 9.0
    minimum_matches: int = 18
    minimum_inliers: int = 12
    lost_after: int = 2
    retrieval_top_k: int = 4
    loop_exclusion: int = 8
    loop_similarity: float = 0.86
    assumed_meters_per_pixel: float = 0.035
    frame_budget_ms: float = 50.0
    blur_threshold: float = 22.0
    max_image_width: int = 960


@dataclass(frozen=True)
class FrameInput:
    frame_id: str
    image: np.ndarray
    timestamp: float
    ground_truth_xyz: tuple[float, float, float] | None = None
    intrinsics: np.ndarray | None = None
    world_from_camera: np.ndarray | None = None


@dataclass
class Keyframe:
    frame_index: int
    features: object
    pose: np.ndarray
    appearance: np.ndarray
    submap: int


@dataclass(frozen=True)
class ReplayResult:
    metrics: dict[str, object]
    trajectory: list[list[float]]


def _rss_mb() -> float:
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return float(value / (1024 * 1024 if os.uname().sysname == "Darwin" else 1024))


def _appearance(features: object) -> np.ndarray:
    descriptor = getattr(features, "global_descriptor", None)
    if descriptor is None:
        values = np.asarray(features.descriptors, dtype=np.float32)
        descriptor = values.mean(axis=0)
    descriptor = np.asarray(descriptor, dtype=np.float32).reshape(-1)
    return descriptor / max(float(np.linalg.norm(descriptor)), 1e-9)


class AppearanceSLAM:
    """Bounded learned-correspondence odometry with an appearance keyframe map.

    Motion comes from robustly fitted learned correspondences. Long-baseline
    appearance retrieval can relocalize a lost tracker or apply loop correction.
    The scale prior is explicit because a single monocular camera cannot observe
    absolute metric scale without an external prior.
    """

    def __init__(self, backend: FeatureBackend, config: LearnedSLAMConfig = LearnedSLAMConfig()) -> None:
        self.backend, self.config = backend, config
        self.keyframes: deque[Keyframe] = deque(maxlen=config.max_keyframes)
        self.pose = np.zeros(3, dtype=np.float64)
        self.world_from_camera = np.eye(4, dtype=np.float64)
        self.previous = None
        self.previous_image: np.ndarray | None = None
        self.failures = self.recoveries = self.lost_streak = self.loops = 0
        self.latencies: list[float] = []
        self.cpu_start = resource.getrusage(resource.RUSAGE_SELF).ru_utime
        self.rows: list[dict[str, object]] = []

    def _resize(self, image: np.ndarray) -> np.ndarray:
        if image.shape[1] <= self.config.max_image_width:
            return image
        scale = self.config.max_image_width / image.shape[1]
        return cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)

    def _retrieve(self, query: np.ndarray, current_index: int) -> list[tuple[float, Keyframe]]:
        candidates = [(float(query @ k.appearance), k) for k in self.keyframes
                      if current_index - k.frame_index > self.config.loop_exclusion]
        return sorted(candidates, key=lambda x: (-x[0], x[1].frame_index))[: self.config.retrieval_top_k]

    def _motion(self, first: object, second: object, intrinsics: np.ndarray | None = None) -> tuple[np.ndarray | None, int, int]:
        matched = self.backend.match(first, second)
        pairs = np.asarray(matched.indices, dtype=np.int32).reshape(-1, 2)
        if len(pairs) < self.config.minimum_matches:
            return None, len(pairs), 0
        a = np.asarray(first.keypoints)[pairs[:, 0]]
        b = np.asarray(second.keypoints)[pairs[:, 1]]
        if intrinsics is not None:
            essential, mask = cv2.findEssentialMat(a, b, intrinsics, method=cv2.RANSAC, prob=0.999, threshold=1.5)
            if essential is not None:
                recovered, rotation, translation, pose_mask = cv2.recoverPose(essential, a, b, intrinsics, mask=mask)
                inliers = int(recovered)
                if inliers >= self.config.minimum_inliers:
                    camera2_from_camera1 = np.eye(4, dtype=np.float64)
                    camera2_from_camera1[:3, :3] = rotation
                    camera2_from_camera1[:3, 3] = translation[:, 0]
                    return np.linalg.inv(camera2_from_camera1), len(pairs), inliers
        affine, mask = cv2.estimateAffinePartial2D(a, b, method=cv2.RANSAC, ransacReprojThreshold=2.5,
                                                   maxIters=1000, confidence=0.995)
        inliers = int(mask.sum()) if mask is not None else 0
        if affine is None or inliers < self.config.minimum_inliers:
            return None, len(pairs), inliers
        dx, dy = float(affine[0, 2]), float(affine[1, 2])
        yaw = math.atan2(float(affine[1, 0]), float(affine[0, 0]))
        # Image motion is opposite camera motion. This is a declared planar car/scale prior.
        return np.array([-dx, -dy, -yaw]) * np.array([self.config.assumed_meters_per_pixel] * 2 + [1.0]), len(pairs), inliers

    def process(self, frame: FrameInput, frame_index: int) -> dict[str, object]:
        started = perf_counter()
        image = self._resize(frame.image)
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        blur = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        lighting = float(gray.mean())
        low_quality = blur < self.config.blur_threshold or lighting < 12 or lighting > 243
        matches = inliers = 0
        status = "initializing"
        features = None
        try:
            features = self.backend.extract(image)
            if self.previous is not None:
                delta, matches, inliers = self._motion(self.previous, features, frame.intrinsics)
                if delta is not None and not low_quality:
                    if delta.shape == (4, 4):
                        self.world_from_camera = self.world_from_camera @ delta
                        self.pose[:] = [self.world_from_camera[0, 3], self.world_from_camera[2, 3],
                                        math.atan2(self.world_from_camera[0, 2], self.world_from_camera[2, 2])]
                    else:
                        self.pose += delta
                        self.world_from_camera[:3, 3] = [self.pose[0], 0, self.pose[1]]
                    status = "tracking"
                    self.lost_streak = 0
                else:
                    self.lost_streak += 1
                    status = "degraded" if self.lost_streak < self.config.lost_after else "lost"
            if status in ("lost", "degraded"):
                retrieved = self._retrieve(_appearance(features), frame_index)
                for similarity, keyframe in retrieved:
                    delta, candidate_matches, candidate_inliers = self._motion(keyframe.features, features, frame.intrinsics)
                    matches, inliers = max(matches, candidate_matches), max(inliers, candidate_inliers)
                    if delta is not None and similarity >= self.config.loop_similarity:
                        if delta.shape == (4, 4):
                            self.world_from_camera = keyframe.pose @ delta
                            self.pose[:] = [self.world_from_camera[0, 3], self.world_from_camera[2, 3],
                                            math.atan2(self.world_from_camera[0, 2], self.world_from_camera[2, 2])]
                        else:
                            self.pose = keyframe.pose + delta
                        self.recoveries += 1
                        self.lost_streak = 0
                        status = "relocalized"
                        break
            if status == "tracking":
                retrieved = self._retrieve(_appearance(features), frame_index)
                if retrieved and retrieved[0][0] >= self.config.loop_similarity:
                    delta, _, loop_inliers = self._motion(retrieved[0][1].features, features, frame.intrinsics)
                    if delta is not None:
                        if delta.shape == (4, 4):
                            target = retrieved[0][1].pose @ delta
                            self.world_from_camera[:3, 3] = 0.75 * self.world_from_camera[:3, 3] + 0.25 * target[:3, 3]
                        else:
                            target = retrieved[0][1].pose + delta
                            self.pose = 0.75 * self.pose + 0.25 * target
                        self.loops += 1
                        inliers = max(inliers, loop_inliers)
            add_keyframe = not self.keyframes or status == "relocalized"
            if self.keyframes:
                if frame.intrinsics is not None:
                    keyframe_distance = np.linalg.norm(self.world_from_camera[:3, 3] - self.keyframes[-1].pose[:3, 3])
                else:
                    keyframe_distance = np.linalg.norm(self.pose[:2] - self.keyframes[-1].pose[:2])
                if keyframe_distance >= self.config.keyframe_translation_px * self.config.assumed_meters_per_pixel:
                    add_keyframe = True
            if add_keyframe and not low_quality:
                stored_pose = self.world_from_camera.copy() if frame.intrinsics is not None else self.pose.copy()
                self.keyframes.append(Keyframe(frame_index, features, stored_pose, _appearance(features), frame_index // self.config.submap_size))
            self.previous = features
            self.previous_image = image
        except Exception as exc:  # a bad frame/model must not terminate a stream
            self.lost_streak += 1
            status = "lost"
            error = f"{type(exc).__name__}: {exc}"
        else:
            error = None
        if status == "lost":
            self.failures += 1
        latency = (perf_counter() - started) * 1000
        self.latencies.append(latency)
        common_status = "relocalized" if status == "relocalized" else ("lost" if status in ("lost", "degraded") else "tracking")
        valid_pose = common_status in ("tracking", "relocalized")
        row = {"frameId": frame.frame_id, "timestamp": frame.timestamp, "status": common_status,
               "trackingSuccess": status in ("initializing", "tracking", "relocalized"),
               "pose": self.pose.tolist(), "trackedFeatures": int(matches), "inliers": int(inliers),
               "blurVariance": blur, "meanIntensity": lighting, "lowQuality": low_quality,
               "latencyMs": latency, "budgetExceeded": latency > self.config.frame_budget_ms,
               "keyframes": len(self.keyframes), "submaps": len({k.submap for k in self.keyframes}), "error": error}
        row["worldFromCameraCV"] = self.world_from_camera.tolist() if valid_pose else None
        self.rows.append(row)
        return row

    def summary(self, frames: list[FrameInput], elapsed: float) -> dict[str, object]:
        estimated = np.asarray([r["pose"] for r in self.rows], dtype=float)
        gt = [f.ground_truth_xyz for f in frames]
        metrics: dict[str, object] = {
            "schemaVersion": 1, "backend": getattr(self.backend, "feature_identity", type(self.backend).__name__),
            "frames": len(self.rows), "trackingSuccessRate": float(np.mean([r["trackingSuccess"] for r in self.rows])) if self.rows else 0.0,
            "failures": self.failures, "recoveries": self.recoveries, "loopClosures": self.loops,
            "mapPoints": int(sum(len(k.features.keypoints) for k in self.keyframes)), "keyframes": len(self.keyframes),
            "mapQuality": float(np.mean([min(1.0, r["inliers"] / max(1, r["trackedFeatures"])) for r in self.rows])),
            "meanTrackedFeatures": float(np.mean([r["trackedFeatures"] for r in self.rows])),
            "meanInliers": float(np.mean([r["inliers"] for r in self.rows])), "fps": len(self.rows) / max(elapsed, 1e-9),
            "meanLatencyMs": float(np.mean(self.latencies)), "p95LatencyMs": float(np.percentile(self.latencies, 95)),
            "rssMB": _rss_mb(), "cpuSeconds": resource.getrusage(resource.RUSAGE_SELF).ru_utime - self.cpu_start,
            "ateRMSE": None, "rpeRMSE": None, "driftPercent": None,
        }
        if gt and all(p is not None for p in gt):
            truth = np.asarray(gt, dtype=float)
            # Align origin only; scale prior remains evaluated rather than optimized away.
            e = estimated - estimated[0] - (truth - truth[0])
            metrics["ateRMSE"] = float(np.sqrt(np.mean(np.sum(e * e, axis=1))))
            de = np.diff(estimated, axis=0) - np.diff(truth, axis=0)
            metrics["rpeRMSE"] = float(np.sqrt(np.mean(np.sum(de * de, axis=1)))) if len(de) else 0.0
            distance = float(np.linalg.norm(np.diff(truth[:, :2], axis=0), axis=1).sum())
            metrics["driftPercent"] = 100 * float(np.linalg.norm(e[-1, :2])) / max(distance, 1e-9)
        return metrics


def run_replay(frames: Iterable[FrameInput], backend: FeatureBackend, config: LearnedSLAMConfig = LearnedSLAMConfig()) -> ReplayResult:
    items = list(frames)
    slam = AppearanceSLAM(backend, config)
    started = perf_counter()
    trajectory = [slam.process(frame, index)["pose"] for index, frame in enumerate(items)]
    return ReplayResult(slam.summary(items, perf_counter() - started), trajectory)


def load_manifest(path: Path) -> list[FrameInput]:
    payload = json.loads(path.read_text())
    root = path.parent
    frames = []
    for index, item in enumerate(payload["frames"]):
        image = cv2.imread(str(root / item["image"]), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError(f"cannot read image: {item['image']}")
        gt = tuple(item["pose"][:3]) if "pose" in item else None
        frames.append(FrameInput(str(item.get("id", index)), image, float(item.get("timestamp", index)), gt))
    return frames


def run_sequence(sequence, backend: FeatureBackend, config: LearnedSLAMConfig = LearnedSLAMConfig()) -> dict[str, object]:
    """Run a common ``SlamSequence`` and emit the neutral evaluator contract."""
    slam = AppearanceSLAM(backend, config)
    cpu_start = resource.getrusage(resource.RUSAGE_SELF).ru_utime
    started = perf_counter()
    records: list[dict[str, object]] = []
    for frame in sequence.frames:
        item = FrameInput(str(frame.index), frame.image(), frame.timestamp,
                          None, sequence.calibration.intrinsics, frame.world_from_camera)
        raw = slam.process(item, frame.index)
        records.append({
            "index": frame.index,
            "timestamp": frame.timestamp,
            "status": raw["status"],
            "worldFromCameraCV": raw["worldFromCameraCV"],
            "trackedFeatures": raw["trackedFeatures"],
            "inliers": raw["inliers"],
            "latencyMilliseconds": raw["latencyMs"],
            "mapPoints": int(sum(len(k.features.keypoints) for k in slam.keyframes)),
            "condition": frame.condition,
        })
    return {
        "schemaVersion": 1,
        "approach": "appearance-learned-map-first",
        "sequence": sequence.name,
        "frames": records,
        "map": {"keyframes": len(slam.keyframes), "submaps": len({k.submap for k in slam.keyframes}),
                "medianReprojectionErrorPixels": None},
        "resources": {"cpuSeconds": resource.getrusage(resource.RUSAGE_SELF).ru_utime - cpu_start,
                      "peakRssBytes": int(_rss_mb() * 1024 * 1024)},
        "wallSeconds": perf_counter() - started,
        "failures": slam.failures,
        "recoveries": slam.recoveries,
        "loopClosures": slam.loops,
    }
