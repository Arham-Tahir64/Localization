# Geometry-first monocular car SLAM

## Scope and design

This implementation is a practical sparse monocular baseline for recorded or streamed, calibrated car-camera frames. It intentionally contains no learned component. Images are converted to grayscale and locally contrast-normalized (CLAHE); Laplacian variance and mean exposure reject blur, darkness, and saturation before they can corrupt state. ORB (FAST corners plus oriented binary descriptors) supplies up to 1,400 repeatable features. A two-nearest-neighbor Hamming ratio test provides motion correspondences, followed by calibrated five-point essential-matrix RANSAC and cheirality-tested pose recovery.

Pose is maintained as `T_world_camera` in the server's right-handed AR camera convention. The implementation imports `AR_CAMERA_FROM_CV_CAMERA`, `validate_rigid_transform`, and `triangulate_track` from the production `housemapper_server.geometry` module; it does not copy or change those contracts. Monocular translation uses a documented nominal 0.075 m/frame gauge. A vehicle deployment should replace that gauge with wheel speed, IMU preintegration, camera height/ground-plane scale, or GPS.

Every eight accepted frames becomes a keyframe. Geometrically supported tracks are triangulated through the production multi-view gate, including positive depth, parallax, and reprojection checks. The bounded 80-keyframe ORB database is used for relocalization candidates when temporal matching cannot provide enough tracks. Candidate retrieval never changes pose by itself: essential-matrix RANSAC must accept it. The latest valid temporal frame remains available across rejected frames, so one or more blurred/exposure-bad images do not poison the next estimate. Tracking has explicit `initializing`, `tracking`, and `lost` states, plus transition-counted failures and recoveries.

This small baseline does not claim full global SLAM: it has sparse triangulation but no local bundle adjustment, covisibility graph, or global loop pose-graph optimization. The database is suitable for adding a vocabulary-tree/BoW index and verified loop edges. Those omissions are deliberate and visible rather than hidden behind a misleading accuracy number.

## Inputs and outputs

The neutral JSON manifest contains a top-level 3x3 `intrinsics` array and `frames`, each with `image`, optional `id`, `timestamp`, per-frame `intrinsics`, and optional row-major 4x4 `pose`. Images resolve relative to the manifest. `pose` is `T_world_camera` in the server AR convention. The KITTI adapter accepts `calib.txt`, `image_0/*`, and optional standard 3x4 pose rows, converting camera axes at its boundary. With neither input option, the CLI generates a deterministic static 3D replay.

The JSON output includes per-frame success/state, feature and inlier counts, image-quality scores, failure reason, map/keyframe size, and latency. Its summary schema includes success rate, failures/recoveries, ATE, RPE, drift, map points, median accepted-pose inliers (`map_quality`), mean tracks/inliers, FPS, p50/p95 latency, peak RSS, and process CPU time. ATE is Sim(3)-aligned because monocular scale is unobservable. RPE is measured after the same alignment. Metrics are `null` when ground truth is absent.

## Common deterministic proxy benchmark

These are **synthetic proxy results, not road-dataset or safety claims**. The shared, approach-neutral `deterministic-car-geometry-v1` sequence renders static geometry into 180 640x360 frames, with labeled low-light, motion-blur, texture-poor, and occluded intervals. Results below come directly from `car_slam.common.evaluation.evaluate_run`, using OpenCV 4.13, NumPy 2.4.3, and the existing server Python environment on the available macOS host.

| Metric | Result |
|---|---:|
| Tracking success | 96.67% (174/180) |
| Loss events / successful recoveries | 1 / 1 (6 frames) |
| Sim(3)-aligned ATE RMSE / median | 1.4679 / 1.4993 m |
| Translation / rotation RPE RMSE | 0.2244 m / 0.5350° |
| Rotation error median | 6.3782° |
| End drift / evaluated GT path | 0.7470% |
| Evaluated / GT frames | 174 / 180 |
| Sparse map points | 2,629 |
| Median matched tracks / inliers | 328 / 151.5 |
| Effective throughput | 106.05 FPS |
| Median / p95 latency | 9.43 / 35.24 ms |
| Peak RSS / CPU time | 86.36 MiB / 5.51 s |

Condition success was nominal 100% (127/127), low light 100% (17/17), motion blur 100% (16/16), texture poor 100% (14/14), and forced occlusion 0% (0/6), followed by recovery. Timing and RSS vary with host load. ATE exposes accumulated monocular shape/scale error; the much smaller endpoint drift does not make the intermediate ATE disappear.

## Methodology and limitations

The common generator is independent of the tracker and supplies metric ground truth. Tests assert deterministic pixels, both manifest contracts, exact Sim(3) metric behavior, successful tracking and recovery across a forced dropout, stable JSON structure, and acceptance by the neutral evaluator. The fixed common replay is intended for regression comparison.

The common adapter deliberately constructs tracker `Frame` objects with `ground_truth=None`; ground-truth CV poses remain in `SlamSequence` and are read only by the common evaluator after inference. A focused leakage test enforces this boundary. Common output is `T_world_camera` with OpenCV axes (`x` right, `y` down, `z` forward): `recoverPose` returns `T_current_reference`, which is inverted and right-composed with the reference `T_world_camera`. AR-axis conversion exists only around imported server triangulation. Losses are counted on the transition into `lost`; a successful pose after loss is explicitly emitted as `relocalized`, so the shared evaluator reports the same single loss and recovery interval. Seven focused tests pass after this audit.

Expected failure cases are low texture, repeated facades, independently moving traffic dominating matches, rolling shutter, long darkness/occlusion, pure rotation, and extremely small baseline. Essential-matrix translation has unknown magnitude and becomes ill-conditioned with little parallax. The current all-scene feature mask can follow moving vehicles; production should add semantic/dynamic masks or multi-model motion segmentation. Descriptor retrieval is linear and perceptual aliases can produce candidates, though geometric verification rejects unsupported ones. Sparse landmarks are not persisted, optimized, or culled globally, so long trajectories will drift.

Strong hybridization points are the transparent quality gate, deterministic state transitions, calibrated geometric verification, server-native pose convention, low compute/memory cost, and explainable inlier/residual signals. Learned SuperPoint/LightGlue correspondences can replace ORB while retaining the essential/PnP gates. IMU/wheel/GPS scale and motion priors can constrain translation. Server map PnP can provide metric relocalization, while a learned place-recognition embedding can shortlist the same keyframe database. A sliding-window BA and loop pose graph fit behind the existing keyframe/map boundary.

## Reproduction

From the repository root:

```bash
PYTHONPATH=server:. /private/tmp/housemapper-server-venv/bin/python -m pytest -q car_slam/tests/test_geometric_*
PYTHONPATH=server:. /private/tmp/housemapper-server-venv/bin/python -m car_slam.approach_geometric.cli --generated-frames 90 --output /tmp/geometric-metrics.json
PYTHONPATH=server:. /private/tmp/housemapper-server-venv/bin/python -m car_slam.common.synthetic_sequence /tmp/geometric-common-benchmark --frames 180
PYTHONPATH=server:. /private/tmp/housemapper-server-venv/bin/python -m car_slam.approach_geometric.cli --sequence /private/tmp/car-slam-shared/sequence.json --output /private/tmp/car-slam-shared/geometric-result.json
PYTHONPATH=server:. /private/tmp/housemapper-server-venv/bin/python -m car_slam.approach_geometric.cli --manifest /path/to/manifest.json --output /tmp/run.json
PYTHONPATH=server:. /private/tmp/housemapper-server-venv/bin/python -m car_slam.approach_geometric.cli --kitti /path/to/sequences/00 --poses /path/to/poses/00.txt
```
