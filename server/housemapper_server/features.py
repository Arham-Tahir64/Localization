from __future__ import annotations

from dataclasses import dataclass
import hashlib
from typing import Protocol

import cv2
import numpy as np

from .errors import MapBuildError


@dataclass(frozen=True)
class ImageFeatures:
    keypoints: np.ndarray
    descriptors: np.ndarray
    scores: np.ndarray
    global_descriptor: np.ndarray
    image_size: tuple[int, int]


@dataclass(frozen=True)
class FeatureMatches:
    indices: np.ndarray
    confidence: np.ndarray


class FeatureBackend(Protocol):
    feature_identity: str
    matcher_identity: str
    descriptor_dimension: int

    def extract(self, image_bgr: np.ndarray) -> ImageFeatures: ...
    def match(self, first: ImageFeatures, second: ImageFeatures) -> FeatureMatches: ...


def aggregate_vlad(descriptors: np.ndarray, centers: np.ndarray) -> np.ndarray:
    values = np.asarray(descriptors, dtype=np.float32)
    vocabulary = np.asarray(centers, dtype=np.float32)
    if values.ndim != 2 or vocabulary.ndim != 2 or values.shape[1] != vocabulary.shape[1]:
        raise ValueError("VLAD descriptors and centers have incompatible shapes")
    distances = (
        np.sum(values * values, axis=1, keepdims=True)
        + np.sum(vocabulary * vocabulary, axis=1)[None]
        - 2 * values @ vocabulary.T
    )
    assignment = np.argmin(distances, axis=1)
    residuals = np.zeros_like(vocabulary)
    np.add.at(residuals, assignment, values - vocabulary[assignment])
    residuals = np.sign(residuals) * np.sqrt(np.abs(residuals) + 1e-12)
    flat = residuals.reshape(-1)
    norm = np.linalg.norm(flat)
    return (flat / max(norm, 1e-12)).astype(np.float32)


def train_vlad_vocabulary(
    descriptors: list[np.ndarray],
    cluster_count: int = 32,
    maximum_samples: int = 50_000,
) -> np.ndarray:
    if not descriptors:
        raise MapBuildError("no descriptors are available for retrieval")
    values = np.concatenate(descriptors, axis=0).astype(np.float32)
    if len(values) < 2:
        raise MapBuildError("too few descriptors are available for retrieval")
    if len(values) > maximum_samples:
        indices = np.linspace(0, len(values) - 1, maximum_samples, dtype=np.int64)
        values = values[indices]
    count = min(cluster_count, len(values))
    cv2.setRNGSeed(20260811)
    _, _, centers = cv2.kmeans(
        values,
        count,
        None,
        (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_MAX_ITER, 100, 1e-4),
        3,
        cv2.KMEANS_PP_CENTERS,
    )
    return centers.astype(np.float32)


class SIFTBaselineBackend:
    """Deterministic CPU baseline. Production maps should use LearnedLightGlueBackend."""

    feature_identity = "OpenCV-SIFT-baseline-v1"
    matcher_identity = "mutual-2NN-ratio-0.78"
    descriptor_dimension = 128

    def __init__(self, maximum_keypoints: int = 4_096) -> None:
        self.maximum_keypoints = maximum_keypoints
        self._extractor = cv2.SIFT_create(
            nfeatures=maximum_keypoints,
            nOctaveLayers=4,
            contrastThreshold=0.015,
            edgeThreshold=12,
            sigma=1.6,
        )
        self._matcher = cv2.BFMatcher(cv2.NORM_L2)

    def extract(self, image_bgr: np.ndarray) -> ImageFeatures:
        gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
        keypoints, descriptors = self._extractor.detectAndCompute(gray, None)
        if descriptors is None or len(keypoints) < 8:
            raise MapBuildError("feature extraction found too little image texture")
        points = np.asarray([point.pt for point in keypoints], dtype=np.float32)
        scores = np.asarray([point.response for point in keypoints], dtype=np.float32)
        descriptors = descriptors.astype(np.float32)
        global_descriptor = np.mean(descriptors, axis=0)
        global_descriptor /= max(float(np.linalg.norm(global_descriptor)), 1e-12)
        return ImageFeatures(
            points,
            descriptors,
            scores,
            global_descriptor.astype(np.float32),
            (int(image_bgr.shape[1]), int(image_bgr.shape[0])),
        )

    def match(self, first: ImageFeatures, second: ImageFeatures) -> FeatureMatches:
        forward = self._matcher.knnMatch(first.descriptors, second.descriptors, k=2)
        reverse = self._matcher.knnMatch(second.descriptors, first.descriptors, k=1)
        reverse_best = {matches[0].queryIdx: matches[0].trainIdx for matches in reverse if matches}
        accepted: list[tuple[int, int]] = []
        confidence: list[float] = []
        for candidates in forward:
            if len(candidates) != 2:
                continue
            best, runner_up = candidates
            ratio = best.distance / max(runner_up.distance, 1e-6)
            if ratio < 0.78 and reverse_best.get(best.trainIdx) == best.queryIdx:
                accepted.append((best.queryIdx, best.trainIdx))
                confidence.append(1.0 - ratio)
        return FeatureMatches(np.asarray(accepted, dtype=np.int32).reshape((-1, 2)), np.asarray(confidence, dtype=np.float32))


class LearnedLightGlueBackend:
    feature_identity = "ALIKED-n16rot-4096"
    matcher_identity = "LightGlue-ALIKED-accuracy"
    descriptor_dimension = 128
    expected_weight_files = {
        "aliked-n16rot.pth": "ddf3abbf38e86f6a74540d214e1a9712c54b2d8551abc864542199f2347d7332",
        "aliked_lightglue_v0-1_arxiv.pth": "d975e965b105311a6143194852297dff4f02aea5cc2e10cecfed966ca0e22503",
    }

    def __init__(self, device: str = "auto", maximum_keypoints: int = 4_096) -> None:
        try:
            import torch
            from lightglue import ALIKED, LightGlue
        except ImportError as error:
            raise MapBuildError(
                "learned backend is unavailable; install the pinned LightGlue dependency from the setup guide"
            ) from error
        from pathlib import Path
        checkpoint_root = Path(torch.hub.get_dir()) / "checkpoints"
        self._torch = torch
        selected = "cuda" if device == "auto" and torch.cuda.is_available() else ("mps" if device == "auto" and torch.backends.mps.is_available() else ("cpu" if device == "auto" else device))
        self.device = selected
        extractor = ALIKED(
            model_name="aliked-n16rot",
            max_num_keypoints=maximum_keypoints,
        ).eval()
        matcher = LightGlue(
            features="aliked",
            depth_confidence=-1,
            width_confidence=-1,
            filter_threshold=0.1,
        ).eval()
        for file_name, expected_digest in self.expected_weight_files.items():
            path = checkpoint_root / file_name
            if not path.is_file():
                raise MapBuildError(f"required learned weight was not installed: {file_name}")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest != expected_digest:
                raise MapBuildError(
                    f"learned weight checksum changed for {file_name}; refusing an incompatible map/model pairing"
                )
        def state_digest(state) -> str:
            digest = hashlib.sha256()
            for key in sorted(state):
                digest.update(key.encode())
                digest.update(state[key].detach().cpu().numpy().tobytes())
            return digest.hexdigest()[:12]
        self.feature_identity = f"{self.feature_identity}-{state_digest(extractor.state_dict())}"
        self.matcher_identity = f"{self.matcher_identity}-{state_digest(matcher.state_dict())}"
        self._extractor = extractor.to(selected)
        self._matcher = matcher.to(selected)

    def _tensor(self, image_bgr: np.ndarray):
        image = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
        return self._torch.from_numpy(image).permute(2, 0, 1).float().div(255).to(self.device)

    def extract(self, image_bgr: np.ndarray) -> ImageFeatures:
        with self._torch.inference_mode():
            prediction = self._extractor.extract(self._tensor(image_bgr))
        keypoints = prediction["keypoints"][0].detach().cpu().numpy().astype(np.float32)
        descriptors = prediction["descriptors"][0].detach().cpu().numpy().astype(np.float32)
        scores_tensor = prediction.get("keypoint_scores")
        scores = scores_tensor[0].detach().cpu().numpy().astype(np.float32) if scores_tensor is not None else np.ones(len(keypoints), dtype=np.float32)
        if len(keypoints) < 8:
            raise MapBuildError("learned feature extraction found too little image texture")
        mean = descriptors.mean(axis=0)
        mean /= max(float(np.linalg.norm(mean)), 1e-12)
        return ImageFeatures(
            keypoints,
            descriptors,
            scores,
            mean.astype(np.float32),
            (int(image_bgr.shape[1]), int(image_bgr.shape[0])),
        )

    def match(self, first: ImageFeatures, second: ImageFeatures) -> FeatureMatches:
        torch = self._torch
        first_data = {
            "keypoints": torch.from_numpy(first.keypoints)[None].to(self.device),
            "descriptors": torch.from_numpy(first.descriptors)[None].to(self.device),
            "image_size": torch.tensor([first.image_size], device=self.device),
        }
        second_data = {
            "keypoints": torch.from_numpy(second.keypoints)[None].to(self.device),
            "descriptors": torch.from_numpy(second.descriptors)[None].to(self.device),
            "image_size": torch.tensor([second.image_size], device=self.device),
        }
        with torch.inference_mode():
            prediction = self._matcher({"image0": first_data, "image1": second_data})
        matches = prediction["matches"][0].detach().cpu().numpy().astype(np.int32)
        scores = prediction["scores"][0].detach().cpu().numpy().astype(np.float32)
        return FeatureMatches(matches, scores)
