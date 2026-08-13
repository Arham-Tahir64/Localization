# Car-camera SLAM comparison and final engineering decision

## Outcome

The current road-test baseline is the **geometry-first pipeline**, not the hybrid. On the exact same 180-frame proxy it had the best trajectory, continuity, latency, CPU use, and memory use. The final sequential hybrid safely combines its tracking with sparse appearance retrieval, but the only loss in this proxy is total camera occlusion. Appearance has no evidence during those frames, so the hybrid cannot improve recovery and only adds overhead.

This is a useful negative result. The hybrid is retained as an experimental integration boundary, but appearance proposals are diagnostic-only until retrieved keyframes carry metric 3D landmarks for PnP or an external scale source is fused. It is not allowed to invent translation magnitude from frame separation.

## Two independent approaches

### A — geometry-first sparse monocular SLAM

- CLAHE-normalized grayscale images and explicit blur/exposure rejection.
- ORB features, Hamming ratio matching, calibrated essential-matrix RANSAC, and cheirality.
- Bounded geometric keyframes and production-server triangulation gates.
- Cheap temporal tracking with geometric retrieval after loss.
- A documented monocular step gauge; no claim of observed metric scale.

This approach supplies explainable inlier counts, bounded resources, and the best short-term motion estimate in the shared test. It still lacks bundle adjustment, a loop pose graph, dynamic-object masking, and physical scale.

### B — appearance-first descriptor SLAM

- Descriptor correspondences on every accepted update rather than an ORB tracking front end.
- Global descriptor retrieval over a bounded keyframe database.
- Calibrated essential geometry after local matching.
- The repository's ALIKED/LightGlue backend is available for deployment; SIFT is the reproducible CPU proxy used in this equal benchmark.

It finds more correspondences and recovers quickly from several one-frame failures, but two-view unit translations accumulate badly without metric scale, local bundle adjustment, or a pose graph. Its 64,026 “map points” are retained feature observations, not 64,026 triangulated metric landmarks, so that count must not be compared directly with the geometric map.

## Benchmark methodology

`car_slam.benchmark` runs each method in a **fresh process** against one immutable sequence manifest. This avoids inherited peak-memory and CPU counters. All methods receive the same decoded images, timestamps, resolution, intrinsics, distortion, and conditions. Ground truth stays in the neutral sequence and is never passed into tracker inference; a focused test enforces that boundary.

The `deterministic-car-geometry-v1` proxy contains 180 frames at 640×360 and 30 FPS over a 70.57 m known trajectory. It injects the same 17 low-light, 16 motion-blurred, 14 texture-poor, and 6 fully occluded frames for every method. The evaluator checks:

- valid tracked/relocalized pose rate and loss/recovery transitions;
- monocular Sim(3)-aligned ATE, RPE, orientation error, and endpoint drift;
- tracked correspondences, inliers, and final map storage count;
- median/p95 per-frame latency, effective FPS, process CPU time, and peak RSS;
- success within each condition.

This proxy is a deterministic regression test, **not physical driving evidence**. It has static procedural geometry, no moving vehicles, rain, rolling shutter, windshield reflections, sun glare, night scenes, high-speed turns, or repeated-place loop. Median map reprojection error is currently unavailable, so map-quality evidence is limited to triangulated-point count and feature/inlier support.

## Exact isolated result

Run on the available macOS host on 2026-08-12 with the repository Python environment and the SIFT appearance proxy:

| Metric | Geometry-first | Appearance-first | Safe sequential hybrid |
|---|---:|---:|---:|
| Successful frames | **174/180 (96.67%)** | 169/180 (93.89%) | **174/180 (96.67%)** |
| Losses / recoveries | **1 / 1** | 5 / 5 | **1 / 1** |
| Median recovery | 6 frames | **1 frame** | 6 frames |
| ATE RMSE | **1.468 m** | 9.158 m | **1.468 m** |
| Translation RPE RMSE | **0.224 m** | 3.739 m | **0.224 m** |
| Rotation RPE RMSE | **0.535°** | 24.958° | **0.535°** |
| Median orientation error | **6.378°** | 91.786° | **6.378°** |
| Endpoint drift | **0.747%** | 20.498% | **0.747%** |
| Median tracks / inliers | 328 / 151.5 | **423 / 315.5** | 328 / 151.5 |
| Final map storage | 2,629 triangulated | 64,026 observations | 2,629 triangulated |
| Median / p95 latency | **9.38 / 35.30 ms** | 52.92 / 105.68 ms | 12.48 / 39.30 ms |
| Effective FPS | **106.66** | 18.90 | 80.16 |
| CPU time | **5.50 s** | 23.68 s | 6.51 s |
| Peak RSS | **90.7 MB** | 181.1 MB | 161.2 MB |

Geometry and hybrid succeeded on every nominal, low-light, blurred, and texture-poor frame, then failed on all six fully occluded frames. Appearance-first succeeded on all nominal and texture-poor frames, 13/17 low-light frames, 15/16 blurred frames, and 0/6 occluded frames.

Timings vary with host load. The result is reproducible with:

```sh
PYTHONPATH=server:. python -m car_slam.benchmark \
  --sequence /path/to/sequence.json \
  --output /tmp/car-slam-results
```

## What the hybrid takes from each approach

From geometry-first:

- sole pose authority during ordinary tracking;
- calibrated RANSAC/cheirality verification;
- explicit quality gates and loss state;
- bounded geometric keyframes and triangulated map.

From appearance-first:

- sparse appearance keyframes;
- global retrieval for old-place proposals;
- stronger local matching backend option;
- explicit proposal/match/verification telemetry.

The hybrid invokes appearance at a low cadence and after geometric loss. It never blends a weaker appearance pose into a valid geometric pose. Even a verified essential-matrix proposal cannot mutate the pose because essential geometry gives only translation direction. An adversarial test proves that a high-inlier, scale-unknown proposal remains non-authoritative.

## Why the hybrid can become better—and why it is not yet

The architecture can improve long-trajectory recovery because global appearance retrieval addresses a failure mode that local temporal matching cannot: returning to a previously mapped place after viewpoint or lighting change. That improvement requires a retrieved keyframe to expose metric 3D landmark associations so `solve_metric_pnp` can estimate a full metric pose. Wheel speed or calibrated IMU preintegration can also supply scale. A verified loop edge must then enter a robust pose graph rather than directly jumping the live pose.

The present benchmark contains no matchable old-place failure; its only loss is total occlusion. Consequently the final hybrid produces zero usable appearance proposals, exactly matches the geometric trajectory, runs about 25% slower, and uses about 78% more peak memory. It demonstrates safe non-degradation of pose, not an accuracy improvement.

## Practical external-camera workflow

Fix the camera rigidly behind the windshield, disable digital stabilization and autofocus changes when the device allows it, and calibrate at the exact recording resolution. Use 20–30 sharp checkerboard images spanning the frame:

```sh
PYTHONPATH=server:. python -m car_slam.common.calibrate calibration-images \
  --columns 9 --rows 6 --square-size 0.024 \
  --output camera-calibration.json
```

Record camera index `0`, a video file, or an RTSP/HTTP stream into the neutral sequence format:

```sh
PYTHONPATH=server:. python -m car_slam.common.capture 0 drive-001 \
  --calibration camera-calibration.json --name drive-001 --frames 1800
```

Replay the current recommended baseline:

```sh
PYTHONPATH=server:. python -m car_slam.approach_geometric.cli \
  --sequence drive-001/sequence.json --output drive-001/result.json
```

The recorder validates that capture resolution matches calibration and preserves measured timestamps. A capture without ground truth supports qualitative trajectory, tracking, resource, and failure analysis, but cannot produce defensible ATE/drift accuracy. Use the existing KITTI adapter for an immediate public ground-truth test, then collect a synchronized RTK-GNSS/INS or surveyed-loop dataset from the actual rig for final validation.

## Remaining bottlenecks and next steps

1. Add wheel speed and IMU timestamps to the neutral observation schema and estimate metric scale.
2. Persist keyframe-to-3D landmark associations; use metric PnP for appearance retrieval.
3. Add a local sliding-window bundle adjustment and robust loop pose graph.
4. Mask moving vehicles/people using semantic or multi-motion segmentation.
5. Add repeated-place, glare/night/rain, rolling-shutter, and high-speed-turn sequences.
6. Run KITTI odometry sequences 00–10 with official trajectory metrics.
7. Capture the actual windshield stream and measure end-to-end decode latency, dropped frames, thermals, and GPU/CPU load.
8. Evaluate production ALIKED/LightGlue only at adaptive cadence; the existing Apple-MPS component benchmark shows its cost is too high for unconditional per-frame use.

For a stronger research baseline on a CUDA machine, compare this implementation with [DPV-SLAM/DPVO](https://github.com/princeton-vl/DPVO) and [MASt3R-SLAM](https://github.com/rmurai0610/MASt3R-SLAM). [ORB-SLAM3](https://github.com/UZ-SLAMLab/ORB_SLAM3) remains a strong mature classical visual/visual-inertial reference. Those external systems should be evaluated through this same neutral sequence/evaluator boundary rather than compared using unrelated headline numbers. The [official KITTI odometry benchmark](https://www.cvlibs.net/datasets/kitti/eval_odometry.php) defines the public road-data split used in the next validation step.
