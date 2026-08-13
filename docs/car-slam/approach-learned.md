# Appearance-first learned car-camera SLAM

## Design

This pipeline is deliberately not an ORB/LK tracker. Every accepted motion update is produced from descriptor correspondences supplied by a feature backend. The production backend imports the repository's pinned ALIKED-n16rot extractor and LightGlue matcher; a deterministic SIFT backend exists only for offline tests and a dependency-free proxy benchmark.

The continuous state is a full rigid `worldFromCameraCV` pose, the previous learned observation, and a bounded deque of appearance keyframes. A keyframe contains local features, a normalized global descriptor, pose, and submap ID. On a calibrated common sequence, consecutive descriptor matches feed essential-matrix RANSAC and cheirality-checked pose recovery. Translation remains up to monocular scale; the common evaluator therefore applies its documented Sim(3) trajectory alignment. The older uncalibrated pan harness retains an explicit `0.035 m/pixel` planar fallback. A production car should recover metric scale from wheel speed, IMU, known camera height/ground plane, or imported metric-map PnP.

Older keyframes are retrieved globally by cosine similarity. Retrieval is used in two ways: after weak/failed consecutive tracking it matches the query against the top candidates and restores the candidate pose plus relative motion; during normal tracking a confident long-baseline match adds a conservative 25% pose correction. The bounded keyframe count, fixed retrieval top-k, image-width cap, and latency-budget flag bound inference and memory. Submap IDs partition keyframes without making retrieval local-only.

Blur variance and mean intensity explicitly gate motion/keyframe insertion. Exceptions from extraction or matching are contained per frame. The external states are exactly `tracking`, `relocalized`, and `lost`; internal weak tracking is conservatively emitted as lost. Failures and recoveries are counted rather than hidden.

The CLI consumes `car_slam.common.dataset.load_sequence` directly and emits the exact common result schema: one indexed record per input frame, a rigid 4×4 `worldFromCameraCV` or null, common status/feature/latency names, map summary, and resource summary. `car_slam.common.evaluation.evaluate_run` supplies tracking success, Sim(3)-aligned ATE/RPE/drift, map observations, FPS/latency, RSS/CPU, loss events, recoveries, and condition breakdown. A minimal neutral manifest is:

```json
{"schemaVersion":1,"name":"drive","fps":30,"camera":{"width":640,"height":360,"intrinsics":[[520,0,320],[0,520,180],[0,0,1]],"distortion":[]},"frames":[{"index":0,"timestamp":0.0,"image":"images/000000.png","condition":"nominal","worldFromCameraCV":[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]}]}
```

Ground truth is optional per frame. Poses use the common right-handed OpenCV camera convention and images resolve relative to the manifest.

## Reproducible methodology and results

Commands (repository root, 2026-08-12):

```sh
/private/tmp/housemapper-server-venv/bin/python -m pytest -q car_slam/tests/test_learned_pipeline.py
/private/tmp/housemapper-server-venv/bin/python -m car_slam.common.synthetic_sequence /tmp/car-common --frames 180
/private/tmp/housemapper-server-venv/bin/python -m car_slam.approach_learned --backend sift-proxy --manifest /tmp/car-common/sequence.json --max-keypoints 800 --output /tmp/learned-common.json
/private/tmp/housemapper-server-venv/bin/python -c 'from car_slam.common.evaluation import evaluate_run; print(evaluate_run("/tmp/car-common/sequence.json", "/tmp/learned-common.json"))'
/private/tmp/housemapper-server-venv/bin/python -m car_slam.approach_learned --backend learned --manifest /path/to/manifest.json --output /tmp/learned-real.json
```

### Shared comparable geometry proxy

On the 180-frame **synthetic proxy** `deterministic-car-geometry-v1`, using the SIFT proxy backend at 800 keypoints, the common evaluator reported 169/180 successful frames (93.89%), five loss events and five successful recoveries with one-frame median recovery. Median/p95 latency was 49.28/100.45 ms (20.29 effective FPS), CPU time 22.39 s, and peak RSS 181,846,016 bytes. Median tracked features/inliers were 423/315.5; the bounded map ended with 64,026 retained feature observations.

After common Sim(3) alignment, ATE RMSE/median was 9.158/6.697 m, translational RPE RMSE 3.739 m, rotational RPE RMSE 24.958°, median rotation error 91.786°, and endpoint drift 20.498% over 70.571 m. Condition success was nominal 100%, low light 76.47%, motion blur 93.75%, texture poor 100%, and occluded 0%. These weak geometry/orientation numbers are intentionally reported: descriptor correspondence and two-view essential geometry without metric scale, bundle adjustment, or an IMU is insufficient for accurate car odometry even though tracking continuity is fairly high.

### Original favorable pan proxy

The earlier deterministic pan replay is a separate **favorable regression proxy**, not a comparable common-sequence or real-driving result. It pans a textured 640×360 crop out and back, injects two strongly blurred frames and one near-black frame, and matches the planar fallback's assumptions. Its SIFT run processed 48 frames at 49.90 FPS, mean/p95 latency 20.03/21.66 ms, 97.92% tracking success, one failed frame, two recoveries, 22 keyframes, 17,609 retained observations, and map quality 0.948. It reported 0.039 m ATE RMSE, 0.058 m RPE RMSE, and approximately 0.0017% terminal drift. These results must not be compared as evidence of perspective driving accuracy.

The repository's separate host synthetic ALIKED/LightGlue measurement (`server/benchmarks/results/macos-mps-2026-08-11.json`) reports ALIKED extraction median 98.81 ms, LightGlue matching median 37.50 ms, VLAD retrieval median 3.89 ms, complete learned localization median 612.93 ms, and roughly 422 MB model-load RSS delta on Apple MPS. These are component/proxy timings, not this continuous pipeline's end-to-end real-road accuracy. They imply production scheduling should extract once per frame, match locally most frames, retrieve less frequently, and use adaptive resolution/keypoint limits.

## Failure cases and hybridizable strengths

Pure rotation, low parallax, large perspective change, repetitive facades, moving traffic dominating the image, rain/night glare, prolonged darkness or blur, and absent metric scale can produce drift or false loops. Essential geometry is used for calibrated streams, but its unit translation and frame-to-frame composition are not a substitute for metric PnP and bundle adjustment. Appearance retrieval has temporal exclusion and geometric verification, but a large deployment should use the existing trained VLAD vocabulary/index rather than this bounded linear scan.

The strongest hybrid is learned ALIKED/LightGlue correspondence and global retrieval paired with metric-map PnP already present in `server.housemapper_server`, wheel/IMU scale, and a pose graph optimizer. Classical short-term optical flow can cheaply bridge frames between learned inference calls, while this pipeline supplies more robust long-baseline matches, explicit loss/recovery, loop candidates, and appearance resilience.
