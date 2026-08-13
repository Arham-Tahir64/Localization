from __future__ import annotations

from dataclasses import dataclass
import os
import resource
import time

import cv2
import numpy as np

from housemapper_server.geometry import AR_CAMERA_FROM_CV_CAMERA, triangulate_track, validate_rigid_transform

from .io import Frame
from .metrics import trajectory_metrics


@dataclass(frozen=True)
class SLAMConfig:
    max_features: int = 1400
    min_tracks: int = 12
    min_inliers: int = 8
    keyframe_gap: int = 8
    blur_threshold: float = 7.0
    exposure_floor: float = 5.0
    exposure_ceiling: float = 250.0
    nominal_step_m: float = 0.075  # monocular gauge; replace with wheel/IMU scale in-car
    seed: int = 7


class GeometricSLAM:
    """Sparse monocular VO/SLAM front end with keyframe map and recovery database."""
    def __init__(self, config: SLAMConfig = SLAMConfig()):
        self.config = config
        cv2.setRNGSeed(config.seed)
        self.orb = cv2.ORB_create(nfeatures=config.max_features, fastThreshold=12)
        self.matcher = cv2.BFMatcher(cv2.NORM_HAMMING)
        self.previous = None
        self.pose_cv = np.eye(4)
        self.keyframes: list[dict] = []
        self.map_points: list[np.ndarray] = []
        self.poses: list[np.ndarray] = []
        self.truth: list[np.ndarray] = []
        self.records: list[dict] = []
        self.failures = self.recoveries = 0
        self.state = "initializing"

    @staticmethod
    def _gray(image):
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
        return cv2.createCLAHE(2.0, (8, 8)).apply(gray)

    def _ar_pose(self):
        pose = self.pose_cv @ AR_CAMERA_FROM_CV_CAMERA
        validate_rigid_transform(pose)
        return pose

    def _features(self, gray):
        keypoints, descriptors = self.orb.detectAndCompute(gray, None)
        return keypoints, descriptors

    def _match(self, first, second):
        if first is None or second is None or len(first) < 2 or len(second) < 2:
            return []
        pairs = self.matcher.knnMatch(first, second, k=2)
        return [a for a, b in pairs if a.distance < .76 * b.distance]

    def process(self, frame: Frame) -> dict:
        started = time.perf_counter(); gray = self._gray(frame.image)
        blur = float(cv2.Laplacian(gray, cv2.CV_64F).var()); exposure = float(np.mean(gray))
        keypoints, descriptors = self._features(gray)
        record = {"frame_id": frame.frame_id, "timestamp": frame.timestamp, "tracked_features": len(keypoints), "inliers": 0,
                  "tracking_success": False, "relocalized": False, "state": self.state,
                  "blur_score": blur, "exposure_mean": exposure, "failure_reason": None}
        guarded = blur < self.config.blur_threshold or not (self.config.exposure_floor <= exposure <= self.config.exposure_ceiling)
        if guarded:
            record["failure_reason"] = "image_quality_guard"
        elif self.previous is None:
            self.state = "tracking"; record["tracking_success"] = True
            self._add_keyframe(frame, gray, keypoints, descriptors)
        else:
            reference = self.previous
            # The bounded keyframe descriptor database doubles as relocalization
            # and loop-candidate retrieval. Geometry still has final authority.
            temporal_matches = self._match(reference["descriptors"], descriptors)
            if self.state == "lost" and len(temporal_matches) < self.config.min_tracks and self.keyframes:
                candidates = [(len(self._match(k["descriptors"], descriptors)), k) for k in self.keyframes]
                _, reference = max(candidates, key=lambda item: item[0])
                temporal_matches = self._match(reference["descriptors"], descriptors)
            matches = temporal_matches
            record["tracked_features"] = len(matches)
            if len(matches) >= self.config.min_tracks:
                p0 = np.float32([reference["keypoints"][m.queryIdx].pt for m in matches])
                p1 = np.float32([keypoints[m.trainIdx].pt for m in matches])
                essential, mask = cv2.findEssentialMat(p0, p1, frame.intrinsics, cv2.RANSAC, .999, 1.25)
                if essential is not None:
                    count, rotation, direction, pose_mask = cv2.recoverPose(essential, p0, p1, frame.intrinsics, mask=mask)
                    record["inliers"] = int(count)
                    if count >= self.config.min_inliers:
                        relative = np.eye(4); relative[:3, :3] = rotation; relative[:3, 3] = direction[:, 0] * self.config.nominal_step_m
                        reference_cv = reference["pose"] @ AR_CAMERA_FROM_CV_CAMERA
                        self.pose_cv = reference_cv @ np.linalg.inv(relative)
                        record["tracking_success"] = True
                        if self.state == "lost":
                            self.recoveries += 1
                            record["relocalized"] = True
                        self.state = "tracking"
                        if frame.frame_id - self.keyframes[-1]["frame_id"] >= self.config.keyframe_gap:
                            self._triangulate_keyframe(frame, reference, p0, p1, pose_mask)
                            self._add_keyframe(frame, gray, keypoints, descriptors)
            if not record["tracking_success"]:
                record["failure_reason"] = record["failure_reason"] or "insufficient_geometric_support"
        if not record["tracking_success"]:
            if self.state != "lost": self.failures += 1
            self.state = "lost"
        elif not guarded:
            self.previous = {"gray": gray, "keypoints": keypoints, "descriptors": descriptors, "frame": frame,
                             "pose": self._ar_pose(), "intrinsics": frame.intrinsics}
        pose = self._ar_pose(); self.poses.append(pose)
        if frame.ground_truth is not None: self.truth.append(frame.ground_truth)
        record.update({"state": self.state, "map_points": len(self.map_points), "keyframes": len(self.keyframes),
                       "latency_ms": (time.perf_counter() - started) * 1000})
        self.records.append(record); return record

    def _add_keyframe(self, frame, gray, keypoints, descriptors):
        self.keyframes.append({"frame_id": frame.frame_id, "gray": gray, "keypoints": keypoints,
                               "descriptors": descriptors, "pose": self._ar_pose(), "intrinsics": frame.intrinsics})
        if len(self.keyframes) > 80: self.keyframes.pop(0)

    def _triangulate_keyframe(self, frame, reference, p0, p1, pose_mask):
        good = np.flatnonzero(pose_mask.ravel() > 0)[:160]
        for index in good:
            result = triangulate_track([(p0[index], reference["intrinsics"], reference["pose"]),
                                        (p1[index], frame.intrinsics, self._ar_pose())], minimum_parallax_degrees=.08)
            if result is not None: self.map_points.append(result[0])

    def summary(self) -> dict:
        latencies = np.asarray([r["latency_ms"] for r in self.records])
        success = sum(bool(r["tracking_success"]) for r in self.records)
        gt_metrics = trajectory_metrics(self.poses, self.truth) if len(self.truth) == len(self.poses) else trajectory_metrics([], [])
        rss_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        rss_mb = rss_kb / 1024 if os.uname().sysname != "Darwin" else rss_kb / (1024 * 1024)
        return {"schema_version": 1, "approach": "geometric", "frames": len(self.records),
                "tracking_success_rate": success / max(len(self.records), 1), "failures": self.failures, "recoveries": self.recoveries,
                "map_points": len(self.map_points), "keyframes": len(self.keyframes),
                "map_quality": float(np.median([r["inliers"] for r in self.records if r["inliers"]])) if any(r["inliers"] for r in self.records) else 0.,
                "tracked_features_mean": float(np.mean([r["tracked_features"] for r in self.records])) if self.records else 0.,
                "inliers_mean": float(np.mean([r["inliers"] for r in self.records])) if self.records else 0.,
                "fps": float(1000 / np.mean(latencies)) if len(latencies) else 0., "latency_ms_p50": float(np.percentile(latencies, 50)) if len(latencies) else 0.,
                "latency_ms_p95": float(np.percentile(latencies, 95)) if len(latencies) else 0., "rss_mb_peak": float(rss_mb),
                "cpu_time_s": float(resource.getrusage(resource.RUSAGE_SELF).ru_utime + resource.getrusage(resource.RUSAGE_SELF).ru_stime), **gt_metrics}


def run_sequence(sequence) -> dict[str, object]:
    """Consume the shared SlamSequence and emit the neutral evaluator contract."""
    slam = GeometricSLAM()
    cpu_before = resource.getrusage(resource.RUSAGE_SELF)
    records = []
    for source in sequence.frames:
        image = source.image()
        distortion = sequence.calibration.distortion
        if distortion.size and np.any(np.abs(distortion) > 1e-12):
            image = cv2.undistort(image, sequence.calibration.intrinsics, distortion)
        frame = Frame(source.index, source.timestamp, image, sequence.calibration.intrinsics, None)
        raw = slam.process(frame)
        valid = bool(raw["tracking_success"])
        records.append({
            "index": source.index, "timestamp": source.timestamp,
            "status": "relocalized" if raw["relocalized"] else "tracking" if valid else "lost",
            "worldFromCameraCV": slam.pose_cv.tolist() if valid else None,
            "trackedFeatures": raw["tracked_features"], "inliers": raw["inliers"],
            "latencyMilliseconds": raw["latency_ms"], "mapPoints": raw["map_points"],
            "condition": source.condition,
        })
    usage = resource.getrusage(resource.RUSAGE_SELF)
    peak = usage.ru_maxrss if os.uname().sysname == "Darwin" else usage.ru_maxrss * 1024
    return {"schemaVersion": 1, "approach": "geometry-first-classical", "sequence": sequence.name,
            "frames": records, "map": {"keyframes": len(slam.keyframes), "medianReprojectionErrorPixels": None},
            "resources": {"cpuSeconds": (usage.ru_utime + usage.ru_stime) - (cpu_before.ru_utime + cpu_before.ru_stime),
                          "peakRssBytes": int(peak)},
            "failures": slam.failures, "recoveries": slam.recoveries, "loopClosures": 0}
