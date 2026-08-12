from __future__ import annotations

from dataclasses import dataclass
from time import perf_counter

import numpy as np

from .contracts import QueryObservation, RESPONSE_SCHEMA
from .errors import ContractError, LocalizationError, MapBuildError
from .features import FeatureBackend, aggregate_vlad
from .geometry import column_major_values, solve_metric_pnp
from .map_store import ServerMap


@dataclass(frozen=True)
class LocalizationConfiguration:
    retrieval_count: int = 10
    minimum_correspondences: int = 50
    minimum_inliers: int = 40
    minimum_inlier_ratio: float = 0.25
    maximum_median_reprojection_error_pixels: float = 3.0
    maximum_individual_reprojection_error_pixels: float = 6.0


@dataclass(frozen=True)
class LocalizationMetrics:
    extracted_keypoints: int
    retrieved_keyframes: int
    raw_matches: int
    unique_correspondences: int
    inliers: int
    median_reprojection_error_pixels: float
    extraction_seconds: float
    retrieval_seconds: float
    matching_seconds: float
    pnp_seconds: float
    retrieved_keyframe_ids: tuple[str, ...]
    retrieval_similarities: tuple[float, ...]

    def json(self) -> dict[str, object]:
        return {
            "extractedKeypoints": self.extracted_keypoints,
            "retrievedKeyframes": self.retrieved_keyframes,
            "rawMatches": self.raw_matches,
            "uniqueCorrespondences": self.unique_correspondences,
            "inliers": self.inliers,
            "medianReprojectionErrorPixels": self.median_reprojection_error_pixels,
            "extractionMilliseconds": self.extraction_seconds * 1_000,
            "retrievalMilliseconds": self.retrieval_seconds * 1_000,
            "matchingMilliseconds": self.matching_seconds * 1_000,
            "pnpMilliseconds": self.pnp_seconds * 1_000,
            "retrievedKeyframeIDs": list(self.retrieved_keyframe_ids),
            "retrievalSimilarities": list(self.retrieval_similarities),
        }


@dataclass(frozen=True)
class LocalizationOutput:
    response: dict
    metrics: LocalizationMetrics


class MetricVisualLocalizer:
    def __init__(
        self,
        server_map: ServerMap,
        backend: FeatureBackend,
        configuration: LocalizationConfiguration = LocalizationConfiguration(),
    ) -> None:
        server_map.validate()
        if server_map.model_identity.get("localFeatures") != backend.feature_identity:
            raise ContractError("loaded feature model does not exactly match the immutable server map")
        if server_map.model_identity.get("matcher") != backend.matcher_identity:
            raise ContractError("loaded matcher does not exactly match the immutable server map")
        self.server_map = server_map
        self.backend = backend
        self.configuration = configuration

    def localize(self, observation: QueryObservation) -> LocalizationOutput:
        if observation.map != self.server_map.reference:
            raise ContractError("query belongs to another immutable server map version")
        extraction_start = perf_counter()
        try:
            query = self.backend.extract(observation.decode_image())
        except MapBuildError as error:
            raise LocalizationError(str(error), stage="extraction") from error
        extraction_seconds = perf_counter() - extraction_start

        def diagnostics(
            *,
            retrieved_keyframes: int = 0,
            raw_matches: int = 0,
            unique_correspondences: int = 0,
            inliers: int = 0,
            median_error: float | None = None,
            retrieval_seconds: float = 0,
            matching_seconds: float = 0,
            pnp_seconds: float = 0,
        ) -> dict[str, object]:
            return {
                "extractedKeypoints": len(query.keypoints),
                "retrievedKeyframes": retrieved_keyframes,
                "rawMatches": raw_matches,
                "uniqueCorrespondences": unique_correspondences,
                "inliers": inliers,
                "medianReprojectionErrorPixels": median_error,
                "extractionMilliseconds": extraction_seconds * 1_000,
                "retrievalMilliseconds": retrieval_seconds * 1_000,
                "matchingMilliseconds": matching_seconds * 1_000,
                "pnpMilliseconds": pnp_seconds * 1_000,
                "retrievedKeyframeIDs": list(retrieved_keyframe_ids),
                "retrievalSimilarities": list(retrieval_similarities),
            }

        retrieval_start = perf_counter()
        query_global = aggregate_vlad(query.descriptors, self.server_map.vlad_centers)
        similarity = self.server_map.retrieval_descriptors @ query_global
        retrieval_count = min(self.configuration.retrieval_count, len(similarity))
        retrieved = np.argsort(-similarity)[:retrieval_count]
        retrieved_keyframe_ids = tuple(
            str(self.server_map.keyframe_ids[int(index)]).upper()
            for index in retrieved
        )
        retrieval_similarities = tuple(float(similarity[index]) for index in retrieved)
        retrieval_seconds = perf_counter() - retrieval_start

        matching_start = perf_counter()
        # Aggregate the same query-to-landmark association across independent
        # retrieved keyframes. Persistent multi-view support is stronger evidence
        # than whichever single pair happened to produce the highest score.
        votes: dict[tuple[int, int], tuple[float, int]] = {}
        raw_matches = 0
        for keyframe_index in retrieved:
            database = self.server_map.keyframe_features(int(keyframe_index))
            try:
                matches = self.backend.match(query, database)
            except MapBuildError as error:
                raise LocalizationError(
                    str(error),
                    stage="matching",
                    diagnostics=diagnostics(
                        retrieved_keyframes=retrieval_count,
                        raw_matches=raw_matches,
                        retrieval_seconds=retrieval_seconds,
                        matching_seconds=perf_counter() - matching_start,
                    ),
                ) from error
            raw_matches += len(matches.indices)
            landmark_ids = self.server_map.keyframe_landmark_ids(int(keyframe_index))
            retrieval_weight = max(0.05, float((similarity[keyframe_index] + 1) / 2))
            for match_index, (query_index, database_index) in enumerate(matches.indices):
                landmark_id = int(landmark_ids[database_index])
                if landmark_id < 0:
                    continue
                score = float(matches.confidence[match_index]) * retrieval_weight
                key = (int(query_index), landmark_id)
                score_sum, support = votes.get(key, (0.0, 0))
                votes[key] = (score_sum + score, support + 1)

        by_query: dict[int, list[tuple[int, float, int]]] = {}
        for (query_index, landmark_id), (score, support) in votes.items():
            by_query.setdefault(query_index, []).append((landmark_id, score, support))
        candidates: dict[int, tuple[int, float, int]] = {}
        for query_index, associations in by_query.items():
            associations.sort(key=lambda item: (-item[2], -item[1], item[0]))
            best = associations[0]
            if len(associations) > 1:
                runner_up = associations[1]
                # Reject a genuinely ambiguous association unless the best
                # landmark has additional independent keyframe support.
                if best[2] <= runner_up[2] and best[1] < runner_up[1] * 1.15:
                    continue
            candidates[query_index] = best

        # A 3D landmark may appear in multiple database images. Enforce a single,
        # highest-confidence query observation for each landmark before PnP.
        by_landmark: dict[int, tuple[int, float, int]] = {}
        for query_index, (landmark_id, score, support) in candidates.items():
            previous = by_landmark.get(landmark_id)
            if previous is None or (support, score) > (previous[2], previous[1]):
                by_landmark[landmark_id] = (query_index, score, support)
        ordered = sorted(
            (
                (query_index, landmark_id, score, support)
                for landmark_id, (query_index, score, support) in by_landmark.items()
            ),
            key=lambda item: (-item[3], -item[2], item[1]),
        )
        if len(ordered) < self.configuration.minimum_correspondences:
            raise LocalizationError(
                f"only {len(ordered)} unique 2D-to-3D matches; need {self.configuration.minimum_correspondences}",
                stage="correspondence",
                diagnostics=diagnostics(
                    retrieved_keyframes=retrieval_count,
                    raw_matches=raw_matches,
                    unique_correspondences=len(ordered),
                    retrieval_seconds=retrieval_seconds,
                    matching_seconds=perf_counter() - matching_start,
                ),
            )
        query_indices = np.asarray([item[0] for item in ordered], dtype=np.int64)
        landmark_ids = np.asarray([item[1] for item in ordered], dtype=np.int64)
        image_points = query.keypoints[query_indices]
        map_points = self.server_map.landmark_positions_for_ids(landmark_ids)
        matching_seconds = perf_counter() - matching_start

        pnp_start = perf_counter()
        try:
            pnp = solve_metric_pnp(
                image_points,
                map_points,
                observation.intrinsics,
                maximum_reprojection_error_pixels=self.configuration.maximum_individual_reprojection_error_pixels,
            )
        except LocalizationError as error:
            raise LocalizationError(
                str(error),
                stage="pnp",
                diagnostics=diagnostics(
                    retrieved_keyframes=retrieval_count,
                    raw_matches=raw_matches,
                    unique_correspondences=len(ordered),
                    retrieval_seconds=retrieval_seconds,
                    matching_seconds=matching_seconds,
                    pnp_seconds=perf_counter() - pnp_start,
                ),
            ) from error
        pnp_seconds = perf_counter() - pnp_start
        inlier_count = len(pnp.inlier_indices)
        inlier_ratio = inlier_count / len(ordered)
        # Swift's contract verifier uses the upper middle sample for even-sized
        # sets, so publish that exact statistic rather than NumPy's mean of two.
        sorted_residuals = np.sort(pnp.residuals_pixels)
        median_error = float(sorted_residuals[len(sorted_residuals) // 2])
        if inlier_count < self.configuration.minimum_inliers:
            raise LocalizationError(
                f"PnP has only {inlier_count} inliers",
                stage="verification",
                diagnostics=diagnostics(
                    retrieved_keyframes=retrieval_count,
                    raw_matches=raw_matches,
                    unique_correspondences=len(ordered),
                    inliers=inlier_count,
                    median_error=median_error,
                    retrieval_seconds=retrieval_seconds,
                    matching_seconds=matching_seconds,
                    pnp_seconds=pnp_seconds,
                ),
            )
        if inlier_ratio < self.configuration.minimum_inlier_ratio:
            raise LocalizationError(
                f"PnP inlier ratio {inlier_ratio:.3f} is too weak",
                stage="verification",
                diagnostics=diagnostics(
                    retrieved_keyframes=retrieval_count,
                    raw_matches=raw_matches,
                    unique_correspondences=len(ordered),
                    inliers=inlier_count,
                    median_error=median_error,
                    retrieval_seconds=retrieval_seconds,
                    matching_seconds=matching_seconds,
                    pnp_seconds=pnp_seconds,
                ),
            )
        if median_error > self.configuration.maximum_median_reprojection_error_pixels:
            raise LocalizationError(
                f"PnP median reprojection error {median_error:.2f}px is too high",
                stage="verification",
                diagnostics=diagnostics(
                    retrieved_keyframes=retrieval_count,
                    raw_matches=raw_matches,
                    unique_correspondences=len(ordered),
                    inliers=inlier_count,
                    median_error=median_error,
                    retrieval_seconds=retrieval_seconds,
                    matching_seconds=matching_seconds,
                    pnp_seconds=pnp_seconds,
                ),
            )

        accepted_landmark_ids = landmark_ids[pnp.inlier_indices]
        accepted_image_points = image_points[pnp.inlier_indices]
        accepted_map_points = map_points[pnp.inlier_indices]
        response = {
            "schemaVersion": RESPONSE_SCHEMA,
            "result": {
                "schemaVersion": RESPONSE_SCHEMA,
                "map": observation.map.json(),
                "sessionID": str(observation.session_id).upper(),
                "frameID": observation.frame_id,
                "capturedAt": observation.captured_at,
                "mapFromCamera": {"values": column_major_values(pnp.map_from_camera)},
                "verification": "visualPnP",
                "quality": {
                    "inlierCount": inlier_count,
                    "inlierRatio": inlier_ratio,
                    "medianReprojectionErrorPixels": median_error,
                    "depthOverlapRatio": None,
                    "depthRMSEMeters": None,
                },
            },
            "inliers": [
                {
                    "x": float(pixel[0]),
                    "y": float(pixel[1]),
                    "mapLandmarkID": int(landmark_id),
                    "mapPosition": {
                        "x": float(position[0]),
                        "y": float(position[1]),
                        "z": float(position[2]),
                    },
                }
                for pixel, landmark_id, position in zip(
                    accepted_image_points,
                    accepted_landmark_ids,
                    accepted_map_points,
                )
            ],
        }
        metrics = LocalizationMetrics(
            len(query.keypoints),
            retrieval_count,
            raw_matches,
            len(ordered),
            inlier_count,
            median_error,
            extraction_seconds,
            retrieval_seconds,
            matching_seconds,
            pnp_seconds,
            retrieved_keyframe_ids,
            retrieval_similarities,
        )
        return LocalizationOutput(response, metrics)
