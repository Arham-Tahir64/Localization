from __future__ import annotations

from dataclasses import dataclass
import math
import os
import resource
from time import perf_counter

import cv2
import numpy as np

from car_slam.approach_geometric.io import Frame
from car_slam.approach_geometric.pipeline import GeometricSLAM, SLAMConfig


@dataclass(frozen=True)
class HybridConfig:
    appearance_keyframe_gap: int = 12
    maximum_appearance_keyframes: int = 48
    retrieval_top_k: int = 4
    temporal_exclusion: int = 8
    minimum_learned_matches: int = 24
    minimum_verified_inliers: int = 18
    minimum_verified_ratio: float = 0.35
    maximum_rotation_degrees: float = 35.0


@dataclass(frozen=True)
class AppearanceProposal:
    verified: bool
    matches: int
    inliers: int
    rotation: np.ndarray | None = None
    translation_direction: np.ndarray | None = None


def _global_descriptor(features) -> np.ndarray:
    value = getattr(features, "global_descriptor", None)
    if value is None:
        value = np.asarray(features.descriptors, dtype=np.float32).mean(axis=0)
    value = np.asarray(value, dtype=np.float32).reshape(-1)
    return value / max(float(np.linalg.norm(value)), 1e-9)


class SequentialHybridSLAM:
    """ORB odometry authority with sparse appearance retrieval for recovery.

    Appearance never changes geometric pose. Essential verification yields a
    diagnostic rotation and unit translation direction only; without metric
    PnP or external scale it is deliberately unable to relocalize.
    """

    def __init__(self, appearance_backend, config: HybridConfig = HybridConfig(),
                 geometric_config: SLAMConfig = SLAMConfig()) -> None:
        self.geometric = GeometricSLAM(geometric_config)
        self.backend = appearance_backend
        self.config = config
        self.appearance_map: list[dict[str, object]] = []
        self.learned_invocations = 0
        self.candidates = self.verified_candidates = self.recoveries = 0

    def _extract(self, image: np.ndarray):
        self.learned_invocations += 1
        return self.backend.extract(image)

    def _insert(self, index: int, image: np.ndarray, pose: np.ndarray, features=None) -> None:
        try:
            features = features if features is not None else self._extract(image)
        except Exception:
            return
        self.appearance_map.append({"index": index, "features": features, "pose": pose.copy(),
                                    "global": _global_descriptor(features)})
        if len(self.appearance_map) > self.config.maximum_appearance_keyframes:
            self.appearance_map.pop(0)

    def _recover(self, index: int, image: np.ndarray, intrinsics: np.ndarray):
        try:
            query = self._extract(image)
        except Exception:
            return AppearanceProposal(False, 0, 0)
        query_global = _global_descriptor(query)
        eligible = [item for item in self.appearance_map
                    if index - int(item["index"]) > self.config.temporal_exclusion]
        ranked = sorted(eligible, key=lambda item: -float(query_global @ item["global"]))[:self.config.retrieval_top_k]
        self.candidates += len(ranked)
        best_counts = (0, 0)
        for candidate in ranked:
            try:
                matches = self.backend.match(candidate["features"], query)
            except Exception:
                continue
            pairs = np.asarray(matches.indices, dtype=np.int32).reshape(-1, 2)
            if len(pairs) < self.config.minimum_learned_matches:
                continue
            first = np.asarray(candidate["features"].keypoints)[pairs[:, 0]]
            second = np.asarray(query.keypoints)[pairs[:, 1]]
            essential, mask = cv2.findEssentialMat(first, second, intrinsics, cv2.RANSAC, 0.999, 1.25)
            if essential is None:
                continue
            count, rotation, direction, _ = cv2.recoverPose(essential, first, second, intrinsics, mask=mask)
            best_counts = max(best_counts, (len(pairs), int(count)), key=lambda pair: pair[1])
            ratio = count / max(len(pairs), 1)
            rotation_degrees = math.degrees(math.acos(float(np.clip((np.trace(rotation) - 1) / 2, -1, 1))))
            if count < self.config.minimum_verified_inliers or ratio < self.config.minimum_verified_ratio:
                continue
            if rotation_degrees > self.config.maximum_rotation_degrees:
                continue
            self.verified_candidates += 1
            return AppearanceProposal(True, len(pairs), int(count), rotation.copy(), direction[:, 0].copy())
        return AppearanceProposal(False, best_counts[0], best_counts[1])

    def process(self, source, calibration) -> dict[str, object]:
        started = perf_counter()
        image = source.image()
        if calibration.distortion.size and np.any(np.abs(calibration.distortion) > 1e-12):
            image = cv2.undistort(image, calibration.intrinsics, calibration.distortion)
        frame = Frame(source.index, source.timestamp, image, calibration.intrinsics, None)
        raw = self.geometric.process(frame)
        valid = bool(raw["tracking_success"])
        status = "tracking" if valid else "lost"
        matches, inliers = int(raw["tracked_features"]), int(raw["inliers"])
        appearance_features = None

        # Low-rate map construction is the only learned work on healthy frames.
        due_keyframe = valid and (not self.appearance_map or source.index - int(self.appearance_map[-1]["index"]) >= self.config.appearance_keyframe_gap)
        if due_keyframe:
            try:
                appearance_features = self._extract(image)
            except Exception:
                appearance_features = None
        if not valid and self.appearance_map:
            proposal = self._recover(source.index, image, calibration.intrinsics)
            matches, inliers = max(matches, proposal.matches), max(inliers, proposal.inliers)
            # Even a verified E candidate has direction but no metric translation.
            # It remains diagnostic until metric-map PnP or external scale exists.
        if valid and due_keyframe:
            self._insert(source.index, image, self.geometric.pose_cv, appearance_features)
        latency_ms = (perf_counter() - started) * 1000
        return {"index": source.index, "timestamp": source.timestamp, "status": status,
                "worldFromCameraCV": self.geometric.pose_cv.tolist() if valid else None,
                "trackedFeatures": matches, "inliers": inliers, "latencyMilliseconds": latency_ms,
                "mapPoints": len(self.geometric.map_points), "condition": source.condition}


def run_sequence(sequence, appearance_backend, config: HybridConfig = HybridConfig()) -> dict[str, object]:
    hybrid = SequentialHybridSLAM(appearance_backend, config)
    before = resource.getrusage(resource.RUSAGE_SELF)
    records = [hybrid.process(frame, sequence.calibration) for frame in sequence.frames]
    after = resource.getrusage(resource.RUSAGE_SELF)
    peak = after.ru_maxrss if os.uname().sysname == "Darwin" else after.ru_maxrss * 1024
    return {"schemaVersion": 1, "approach": "sequential-geometry-learned-hybrid", "sequence": sequence.name,
            "frames": records,
            "map": {"keyframes": len(hybrid.geometric.keyframes),
                    "appearanceKeyframes": len(hybrid.appearance_map),
                    "medianReprojectionErrorPixels": None},
            "resources": {"cpuSeconds": (after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime),
                          "peakRssBytes": int(peak)},
            "failures": hybrid.geometric.failures, "recoveries": hybrid.recoveries,
            "learnedInvocations": hybrid.learned_invocations, "retrievalCandidates": hybrid.candidates,
            "geometricallyVerifiedCandidates": hybrid.verified_candidates}
