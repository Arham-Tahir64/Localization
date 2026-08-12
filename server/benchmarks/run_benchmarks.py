from __future__ import annotations

import argparse
import json
import math
import platform
from statistics import median
from time import perf_counter

import cv2
import numpy as np
import psutil
from uuid import UUID

from housemapper_server.contracts import ImageGeometry, MapReference, QueryObservation
from housemapper_server.features import LearnedLightGlueBackend, aggregate_vlad, train_vlad_vocabulary
from housemapper_server.geometry import pose_delta, project_map_points, solve_metric_pnp
from housemapper_server.localizer import LocalizationConfiguration, MetricVisualLocalizer
from housemapper_server.map_store import ServerMap


def textured_image(width: int = 1280, height: int = 960) -> np.ndarray:
    rng = np.random.default_rng(20260811)
    image = np.full((height, width, 3), 32, dtype=np.uint8)
    for index in range(600):
        center = tuple(rng.integers([10, 10], [width - 10, height - 10]))
        color = tuple(int(value) for value in rng.integers(50, 255, 3))
        if index % 3 == 0:
            cv2.circle(image, center, int(rng.integers(2, 10)), color, -1)
        else:
            end = tuple(np.clip(np.asarray(center) + rng.integers(-30, 31, 2), [0, 0], [width - 1, height - 1]))
            cv2.line(image, center, end, color, int(rng.integers(1, 4)))
    cv2.putText(image, "HOUSEMAPPER METRIC LOCALIZATION", (80, 470), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (235, 235, 235), 3, cv2.LINE_AA)
    return image


def transformed_view(image: np.ndarray) -> np.ndarray:
    height, width = image.shape[:2]
    source = np.float32([[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]])
    destination = np.float32([[38, 24], [width - 55, 12], [width - 20, height - 36], [25, height - 10]])
    homography = cv2.getPerspectiveTransform(source, destination)
    output = cv2.warpPerspective(image, homography, (width, height), borderMode=cv2.BORDER_REFLECT)
    return cv2.convertScaleAbs(output, alpha=0.88, beta=18)


def timing(operation, iterations: int, warmup: int = 1) -> dict:
    for _ in range(warmup):
        operation()
    values = []
    for _ in range(iterations):
        start = perf_counter()
        operation()
        values.append((perf_counter() - start) * 1_000)
    ordered = sorted(values)
    p95 = ordered[min(len(ordered) - 1, math.ceil(0.95 * len(ordered)) - 1)]
    return {
        "iterations": iterations,
        "medianMilliseconds": median(values),
        "p95Milliseconds": p95,
        "maximumMilliseconds": max(values),
    }


def benchmark(device: str, iterations: int) -> dict:
    process = psutil.Process()
    rss_before = process.memory_info().rss
    model_start = perf_counter()
    backend = LearnedLightGlueBackend(device=device)
    model_load_seconds = perf_counter() - model_start
    rss_after_model = process.memory_info().rss

    first_image = textured_image()
    second_image = transformed_view(first_image)
    first = backend.extract(first_image)
    second = backend.extract(second_image)
    matches = backend.match(first, second)
    extraction = timing(lambda: backend.extract(first_image), iterations)
    matching = timing(lambda: backend.match(first, second), iterations)
    rss_after_inference = process.memory_info().rss

    # Run the production localizer end-to-end with a real learned query and ten
    # retrieved learned database views. The 3D points are synthetic only so the
    # benchmark can exercise PnP/response construction without claiming pose accuracy.
    image_keypoint_count = len(first.keypoints)
    map_keypoint_count = max(image_keypoint_count, 64)
    benchmark_map_points = np.column_stack((
        (first.keypoints[:, 0] - 640) * 4 / 900,
        -(first.keypoints[:, 1] - 480) * 4 / 900,
        np.full(image_keypoint_count, -4.0),
    )).astype(np.float32)
    benchmark_landmark_ids = np.arange(1, image_keypoint_count + 1, dtype=np.int64)
    keyframe_count = 10
    vlad_benchmark_centers = train_vlad_vocabulary([first.descriptors], cluster_count=16)
    benchmark_global = aggregate_vlad(first.descriptors, vlad_benchmark_centers)
    benchmark_reference = MapReference(UUID("11111111-2222-3333-4444-555555555555"), UUID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    benchmark_server_map = ServerMap(
        benchmark_reference,
        {
            "reconstruction": "synthetic-benchmark-only",
            "retrieval": "map-VLAD-k16",
            "localFeatures": backend.feature_identity,
            "matcher": backend.matcher_identity,
        },
        tuple(UUID(int=index + 1) for index in range(keyframe_count)),
        np.tile(np.array([[1280, 960]], dtype=np.int32), (keyframe_count, 1)),
        np.arange(0, (keyframe_count + 1) * image_keypoint_count, image_keypoint_count, dtype=np.int64),
        np.tile(first.keypoints, (keyframe_count, 1)),
        np.tile(first.descriptors, (keyframe_count, 1)),
        np.tile(benchmark_landmark_ids, keyframe_count),
        np.tile(benchmark_global, (keyframe_count, 1)),
        vlad_benchmark_centers,
        benchmark_landmark_ids,
        benchmark_map_points,
        first.descriptors,
        np.full(image_keypoint_count, keyframe_count, dtype=np.int16),
    )
    ok, benchmark_jpeg = cv2.imencode(".jpg", first_image, [cv2.IMWRITE_JPEG_QUALITY, 82])
    assert ok
    benchmark_observation = QueryObservation(
        benchmark_reference,
        UUID("00000000-0000-0000-0000-000000000001"),
        1,
        1.0,
        ImageGeometry(1280, 960, "right", "rearWide"),
        np.array([[900, 0, 640], [0, 900, 480], [0, 0, 1]], dtype=np.float64),
        np.eye(4),
        benchmark_jpeg.tobytes(),
    )
    full_localizer = MetricVisualLocalizer(
        benchmark_server_map,
        backend,
        LocalizationConfiguration(
            retrieval_count=keyframe_count,
            minimum_correspondences=40,
            minimum_inliers=40,
        ),
    )
    full_output = None

    def full_localize():
        nonlocal full_output
        full_output = full_localizer.localize(benchmark_observation)

    complete_localization = timing(full_localize, max(3, iterations // 2), warmup=1)

    rng = np.random.default_rng(42)
    descriptor_samples = [rng.normal(size=(4_096, 128)).astype(np.float32) for _ in range(12)]
    for sample in descriptor_samples:
        sample /= np.linalg.norm(sample, axis=1, keepdims=True)
    centers = train_vlad_vocabulary(descriptor_samples, cluster_count=32)
    database = np.stack([aggregate_vlad(sample, centers) for sample in descriptor_samples])
    query = descriptor_samples[0]

    def retrieve():
        query_descriptor = aggregate_vlad(query, centers)
        return np.argsort(-(database @ query_descriptor))[:10]

    retrieval = timing(retrieve, max(20, iterations * 5), warmup=2)

    intrinsics = np.array([[900, 0, 640], [0, 900, 480], [0, 0, 1]], dtype=float)
    expected = np.eye(4)
    angle = math.radians(12)
    expected[:3, :3] = [[math.cos(angle), 0, math.sin(angle)], [0, 1, 0], [-math.sin(angle), 0, math.cos(angle)]]
    expected[:3, 3] = [0.7, 0.2, -0.4]
    points = np.column_stack((rng.uniform(-3, 3, 500), rng.uniform(-2, 2, 500), rng.uniform(-9, -3, 500)))
    pixels, _ = project_map_points(points, intrinsics, expected)
    pixels += rng.normal(0, 0.4, pixels.shape)
    pixels[:100] = rng.uniform([0, 0], [1280, 960], (100, 2))
    last_pose = None

    def pnp():
        nonlocal last_pose
        last_pose = solve_metric_pnp(pixels, points, intrinsics)

    pnp_timing = timing(pnp, max(50, iterations * 10), warmup=2)
    translation_error, rotation_error = pose_delta(last_pose.map_from_camera, expected)

    return {
        "environment": {
            "kind": "host-synthetic-performance-not-accuracy",
            "platform": platform.platform(),
            "python": platform.python_version(),
            "opencv": cv2.__version__,
            "numpy": np.__version__,
            "device": backend.device,
            "note": "Synthetic timing and coordinate sanity only; not iPhone latency or physical localization accuracy.",
        },
        "models": {
            "features": backend.feature_identity,
            "matcher": backend.matcher_identity,
            "loadSeconds": model_load_seconds,
        },
        "learnedFeatures": {
            "image": {"width": 1280, "height": 960},
            "firstKeypoints": len(first.keypoints),
            "secondKeypoints": len(second.keypoints),
            "matches": len(matches.indices),
            "extraction": extraction,
            "matching": matching,
        },
        "retrieval": {
            "databaseKeyframes": len(database),
            "descriptorSamplesPerKeyframe": 4_096,
            "vladClusters": len(centers),
            "timing": retrieval,
        },
        "completeLearnedLocalization": {
            "retrievedKeyframes": keyframe_count,
            "queryKeypoints": full_output.metrics.extracted_keypoints,
            "rawMatches": full_output.metrics.raw_matches,
            "uniqueCorrespondences": full_output.metrics.unique_correspondences,
            "inliers": full_output.metrics.inliers,
            "responseInliers": len(full_output.response["inliers"]),
            "timing": complete_localization,
        },
        "pnp": {
            "correspondences": len(points),
            "outliers": 100,
            "inliers": len(last_pose.inlier_indices),
            "translationErrorMeters": translation_error,
            "rotationErrorDegrees": math.degrees(rotation_error),
            "medianResidualPixels": float(np.median(last_pose.residuals_pixels)),
            "timing": pnp_timing,
        },
        "memory": {
            "rssBeforeBytes": rss_before,
            "rssAfterModelBytes": rss_after_model,
            "rssAfterInferenceBytes": rss_after_inference,
            "modelDeltaBytes": rss_after_model - rss_before,
            "inferenceDeltaBytes": rss_after_inference - rss_after_model,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    parser.add_argument("--iterations", type=int, default=10)
    arguments = parser.parse_args()
    if arguments.iterations < 3:
        parser.error("--iterations must be at least 3")
    print(json.dumps(benchmark(arguments.device, arguments.iterations), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
