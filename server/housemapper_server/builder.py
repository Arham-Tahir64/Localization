from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
from time import perf_counter
from typing import Callable

import cv2
import numpy as np

from .contracts import MappingPackage
from .errors import MapBuildError
from .features import FeatureBackend, ImageFeatures, aggregate_vlad, train_vlad_vocabulary
from .geometry import filter_calibrated_pair_matches, triangulate_track
from .map_store import ServerMap, new_map_reference, write_server_map


@dataclass(frozen=True)
class BuildConfiguration:
    sequential_window: int = 4
    nearest_pose_neighbors: int = 10
    retrieval_neighbors: int = 8
    minimum_pair_inliers: int = 18
    minimum_track_length: int = 2
    minimum_parallax_degrees: float = 1.25
    maximum_triangulation_median_error_pixels: float = 2.5
    minimum_landmarks: int = 80
    vlad_cluster_count: int = 32


@dataclass(frozen=True)
class BuildMetrics:
    keyframes: int
    extracted_keypoints: int
    candidate_pairs: int
    accepted_pairs: int
    raw_matches: int
    geometrically_valid_matches: int
    landmarks: int
    extraction_seconds: float
    matching_seconds: float
    triangulation_seconds: float


@dataclass(frozen=True)
class BuildResult:
    directory: Path
    server_map: ServerMap
    metrics: BuildMetrics


class _TrackUnion:
    def __init__(self, observation_count: int, observation_frames: np.ndarray) -> None:
        self.parent = np.arange(observation_count, dtype=np.int64)
        self.size = np.ones(observation_count, dtype=np.int32)
        # At most 120 keyframes: a Python integer is a compact frame-membership
        # bitset and avoids allocating one set object for every image keypoint.
        self.frame_masks = [1 << int(observation_frames[index]) for index in range(observation_count)]

    def find(self, value: int) -> int:
        root = value
        while int(self.parent[root]) != root:
            root = int(self.parent[root])
        while int(self.parent[value]) != value:
            next_value = int(self.parent[value])
            self.parent[value] = root
            value = next_value
        return root

    def union(self, first: int, second: int) -> bool:
        first_root, second_root = self.find(first), self.find(second)
        if first_root == second_root:
            return True
        if self.frame_masks[first_root] & self.frame_masks[second_root]:
            return False
        if self.size[first_root] < self.size[second_root]:
            first_root, second_root = second_root, first_root
        self.parent[second_root] = first_root
        self.size[first_root] += self.size[second_root]
        self.frame_masks[first_root] |= self.frame_masks[second_root]
        self.frame_masks[second_root] = 0
        return True


def _candidate_pairs(
    package: MappingPackage,
    features: list[ImageFeatures],
    configuration: BuildConfiguration,
) -> list[tuple[int, int]]:
    count = len(package.keyframes)
    pairs: set[tuple[int, int]] = set()
    for first in range(count):
        for second in range(first + 1, min(count, first + 1 + configuration.sequential_window)):
            pairs.add((first, second))

    positions = np.stack([frame.map_from_camera[:3, 3] for frame in package.keyframes])
    distances = np.linalg.norm(positions[:, None] - positions[None], axis=2)
    np.fill_diagonal(distances, np.inf)
    for first in range(count):
        nearest = np.argsort(distances[first])[: configuration.nearest_pose_neighbors]
        for second in nearest:
            pairs.add(tuple(sorted((first, int(second)))))

    globals_matrix = np.stack([feature.global_descriptor for feature in features])
    similarity = globals_matrix @ globals_matrix.T
    np.fill_diagonal(similarity, -np.inf)
    for first in range(count):
        nearest = np.argsort(-similarity[first])[: configuration.retrieval_neighbors]
        for second in nearest:
            pairs.add(tuple(sorted((first, int(second)))))
    return sorted(pairs)


def build_metric_map(
    package: MappingPackage,
    backend: FeatureBackend,
    destination_root: Path,
    query_endpoint: str,
    configuration: BuildConfiguration = BuildConfiguration(),
    progress: Callable[[str], None] = print,
) -> BuildResult:
    progress(f"Extracting {backend.feature_identity} features from {len(package.keyframes)} calibrated keyframes…")
    extraction_start = perf_counter()
    features: list[ImageFeatures] = []
    for index, keyframe in enumerate(package.keyframes):
        image = cv2.imread(str(keyframe.image_path), cv2.IMREAD_COLOR)
        if image is None:
            raise MapBuildError(f"could not decode keyframe {keyframe.image_path.name}")
        extracted = backend.extract(image)
        if extracted.image_size != (keyframe.geometry.width, keyframe.geometry.height):
            raise MapBuildError("feature extractor changed calibrated image geometry")
        features.append(extracted)
        progress(f"  [{index + 1}/{len(package.keyframes)}] {len(extracted.keypoints)} keypoints")
    extraction_seconds = perf_counter() - extraction_start

    offsets = np.zeros(len(features) + 1, dtype=np.int64)
    offsets[1:] = np.cumsum([len(item.keypoints) for item in features])
    observation_frames = np.concatenate([
        np.full(len(item.keypoints), index, dtype=np.int32) for index, item in enumerate(features)
    ])
    tracks = _TrackUnion(int(offsets[-1]), observation_frames)
    pairs = _candidate_pairs(package, features, configuration)
    progress(f"Matching {len(pairs)} pose/retrieval-selected keyframe pairs with {backend.matcher_identity}…")
    matching_start = perf_counter()
    accepted_pairs = 0
    accepted_pair_edges: list[tuple[int, int]] = []
    raw_matches = 0
    geometrically_valid_matches = 0
    for pair_number, (first, second) in enumerate(pairs):
        matches = backend.match(features[first], features[second])
        raw_matches += len(matches.indices)
        valid: list[tuple[int, int]] = []
        if len(matches.indices):
            valid_mask = filter_calibrated_pair_matches(
                features[first].keypoints[matches.indices[:, 0]],
                features[second].keypoints[matches.indices[:, 1]],
                package.keyframes[first].intrinsics,
                package.keyframes[second].intrinsics,
                package.keyframes[first].map_from_camera,
                package.keyframes[second].map_from_camera,
                minimum_parallax_degrees=configuration.minimum_parallax_degrees,
                maximum_median_error_pixels=configuration.maximum_triangulation_median_error_pixels,
            )
            valid = [
                (int(first_index), int(second_index))
                for first_index, second_index in matches.indices[valid_mask]
            ]
        if len(valid) >= configuration.minimum_pair_inliers:
            accepted_pairs += 1
            accepted_pair_edges.append((first, second))
            geometrically_valid_matches += len(valid)
            for first_index, second_index in valid:
                tracks.union(int(offsets[first] + first_index), int(offsets[second] + second_index))
        if (pair_number + 1) % 25 == 0 or pair_number + 1 == len(pairs):
            progress(f"  [{pair_number + 1}/{len(pairs)}] {accepted_pairs} geometrically accepted pairs")
    matching_seconds = perf_counter() - matching_start
    connected_frames = {0}
    changed = True
    while changed:
        changed = False
        for first, second in accepted_pair_edges:
            if first in connected_frames and second not in connected_frames:
                connected_frames.add(second)
                changed = True
            elif second in connected_frames and first not in connected_frames:
                connected_frames.add(first)
                changed = True
    if len(connected_frames) != len(package.keyframes):
        raise MapBuildError(
            f"the calibrated view graph contains only {len(connected_frames)}/{len(package.keyframes)} connected keyframes; rescan with slower motion and more overlapping views"
        )

    progress("Triangulating persistent metric landmark tracks…")
    triangulation_start = perf_counter()
    observations_by_root: dict[int, list[int]] = {}
    for observation_index in range(int(offsets[-1])):
        root = tracks.find(observation_index)
        observations_by_root.setdefault(root, []).append(observation_index)

    keypoint_landmark_ids = np.full(int(offsets[-1]), -1, dtype=np.int64)
    landmark_positions: list[np.ndarray] = []
    landmark_descriptors: list[np.ndarray] = []
    track_lengths: list[int] = []
    for observation_indices in observations_by_root.values():
        if len(observation_indices) < configuration.minimum_track_length:
            continue
        observations: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
        descriptors: list[np.ndarray] = []
        unique_frames: set[int] = set()
        for flat_index in observation_indices:
            frame_index = int(observation_frames[flat_index])
            if frame_index in unique_frames:
                observations = []
                break
            unique_frames.add(frame_index)
            local_index = flat_index - int(offsets[frame_index])
            observations.append((
                features[frame_index].keypoints[local_index],
                package.keyframes[frame_index].intrinsics,
                package.keyframes[frame_index].map_from_camera,
            ))
            descriptors.append(features[frame_index].descriptors[local_index])
        if not observations:
            continue
        triangulated = triangulate_track(
            observations,
            minimum_parallax_degrees=configuration.minimum_parallax_degrees,
            maximum_median_error_pixels=configuration.maximum_triangulation_median_error_pixels,
        )
        if triangulated is None:
            continue
        point, _ = triangulated
        descriptor = np.mean(np.stack(descriptors), axis=0)
        descriptor /= max(float(np.linalg.norm(descriptor)), 1e-12)
        landmark_id = len(landmark_positions) + 1
        for flat_index in observation_indices:
            keypoint_landmark_ids[flat_index] = landmark_id
        landmark_positions.append(point)
        landmark_descriptors.append(descriptor.astype(np.float32))
        track_lengths.append(len(observations))
    triangulation_seconds = perf_counter() - triangulation_start
    if len(landmark_positions) < configuration.minimum_landmarks:
        raise MapBuildError(
            f"only {len(landmark_positions)} verified landmarks survived; at least {configuration.minimum_landmarks} are required"
        )

    vocabulary = train_vlad_vocabulary(
        [item.descriptors for item in features],
        cluster_count=configuration.vlad_cluster_count,
    )
    retrieval_descriptors = np.stack([
        aggregate_vlad(item.descriptors, vocabulary) for item in features
    ])
    server_map = ServerMap(
        new_map_reference(package.map_id),
        {
            "reconstruction": "HouseMapper-metric-triangulation-v1",
            "retrieval": f"map-VLAD-k{len(vocabulary)}",
            "localFeatures": backend.feature_identity,
            "matcher": backend.matcher_identity,
        },
        tuple(frame.keyframe_id for frame in package.keyframes),
        np.asarray([item.image_size for item in features], dtype=np.int32),
        offsets,
        np.concatenate([item.keypoints for item in features]).astype(np.float32),
        np.concatenate([item.descriptors for item in features]).astype(np.float32),
        keypoint_landmark_ids,
        retrieval_descriptors.astype(np.float32),
        vocabulary.astype(np.float32),
        np.arange(1, len(landmark_positions) + 1, dtype=np.int64),
        np.stack(landmark_positions).astype(np.float32),
        np.stack(landmark_descriptors).astype(np.float32),
        np.asarray(track_lengths, dtype=np.int16),
    )
    directory = write_server_map(
        destination_root,
        server_map,
        query_endpoint=query_endpoint,
        map_name=package.name,
    )
    metrics = BuildMetrics(
        len(features),
        int(offsets[-1]),
        len(pairs),
        accepted_pairs,
        raw_matches,
        geometrically_valid_matches,
        len(landmark_positions),
        extraction_seconds,
        matching_seconds,
        triangulation_seconds,
    )
    return BuildResult(directory, server_map, metrics)
