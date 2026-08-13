# Sequential geometry/appearance car SLAM hybrid

## Decision and safety model

This hybrid keeps `GeometricSLAM` as the sole authority during healthy tracking. ORB correspondences, essential-matrix RANSAC, cheirality, the geometric keyframe map, and the existing monocular step-scale convention produce the normal pose stream. It does not average geometric and appearance poses.

The second stage builds a bounded appearance map at a low cadence (every 12 successful frames, at most 48 keyframes). The default benchmark backend is the repository's SIFT proxy; selecting `--backend learned` imports the pinned ALIKED/LightGlue implementation. Appearance inference is otherwise activated only when geometric inliers degrade or tracking is lost.

On loss, global descriptor cosine similarity proposes at most four old places, excluding the most recent eight frames. Its local descriptor matches can be marked geometrically verified only after all of:

- at least 24 raw matches;
- essential-matrix RANSAC with calibrated intrinsics;
- at least 18 recovered-pose inliers and 35% inlier ratio;
- cheirality through `recoverPose`;
- relative rotation no larger than 35 degrees.

Even after those checks, an essential matrix supplies only rotation and a unit translation direction. The hybrid therefore keeps both verified and unverified appearance candidates diagnostic-only: neither can install or blend a pose, mutate geometric state, or emit `relocalized`. Metric-map PnP or external metric translation is a prerequisite for enabling appearance relocalization. This avoids the unsafe shortcut of multiplying translation direction by temporal frame span. No ground truth or condition label enters tracking decisions.

Healthy-frame appearance extraction occurs only on the scheduled 12-frame cache cadence. Extraction formerly triggered by low geometric inlier count was removed because, without a metric recovery consumer, that result was discarded. Lost frames still attempt a query; the implementation does not special-case known occlusion or inspect condition labels.

The CLI consumes `car_slam.common.dataset.load_sequence` and emits the exact common schema: one indexed record per input frame, status `tracking`, `relocalized`, or `lost`, and a valid 4×4 `worldFromCameraCV` or null. Resource, feature, map, invocation, proposal, verification, and recovery counts are included.

## Commands

From the repository root on 2026-08-12:

```sh
/private/tmp/housemapper-server-venv/bin/python -m pytest -q car_slam/tests/test_hybrid_pipeline.py
/private/tmp/housemapper-server-venv/bin/python -m car_slam.common.synthetic_sequence /tmp/car-hybrid --frames 180
/private/tmp/housemapper-server-venv/bin/python -m car_slam.hybrid --sequence /tmp/car-hybrid/sequence.json --backend sift-proxy --max-keypoints 800 --output /tmp/hybrid-common-result.json
/private/tmp/housemapper-server-venv/bin/python -m car_slam.common.evaluate /tmp/car-hybrid/sequence.json /tmp/hybrid-common-result.json
```

## Comparable proxy result

This is the same 180-frame `deterministic-car-geometry-v1` **synthetic proxy**, not physical driving evidence. The SIFT-proxy hybrid produced:

| Metric | Geometry | Learned | Sequential hybrid |
|---|---:|---:|---:|
| Successful frames | 174/180 (96.67%) | 169/180 (93.89%) | 174/180 (96.67%) |
| Loss / evaluator recovery | 1 / 1 in 6 frames | 5 / 5, median 1 frame | 1 / 1 in 6 frames |
| ATE RMSE | 1.4679 m | 9.158 m | 1.4679 m |
| Translation RPE RMSE | 0.2244 m | — | 0.2244 m |
| Rotation RPE RMSE | 0.535° | — | 0.535° |
| Endpoint drift | 0.747% | 20.498% | 0.747% |
| Effective FPS | 104.35 | about 18.6–20.3 | 80.04 |
| Median / p95 latency | 9.58 / 36.18 ms | about 49 / 100 ms | 12.49 / 38.78 ms |
| CPU time | 5.50 s | about 22.4 s | 6.38 s |
| Peak RSS | 92,520,448 B | about 183 MB | 158,990,336 B |

The safe hybrid invoked appearance extraction 21 times and retained 15 appearance keyframes. During the six fully occluded frames, appearance extraction could not produce a usable query, so it proposed zero retrieval candidates; no appearance recovery is installable by design. The geometric tracker recovered naturally on the first visible frame. Final geometric map points were 2,629; median tracked features/inliers were 328/151.5. Condition success was 100% for nominal, low-light, motion-blur, and texture-poor frames, and 0% for occlusion.

## Did it improve?

No, not on this benchmark. Accuracy and continuity are exactly the geometric baseline because appearance is diagnostic-only until metric translation exists. The sequential policy successfully prevented the much weaker learned trajectory—or a scale-invented essential translation—from degrading geometric poses, but paid roughly 23% lower effective FPS, 16% more CPU time, and 72% higher peak RSS. That is a safety property and an architectural staging point, not a benchmark-quality win.

The result is also an important limitation of this synthetic sequence: its sole geometric loss is total occlusion, where neither classical nor learned appearance can recover until vision returns. A fair demonstration of hybrid benefit needs a repeated-place sequence with large viewpoint/illumination change where consecutive geometry fails but an older appearance keyframe remains matchable. Production ALIKED/LightGlue may improve proposal recall under such changes, but its existing MPS component timings and memory cost make sparse invocation essential.

## Failure cases and next hybrid steps

The hybrid still cannot solve total occlusion, metric scale, perceptual aliasing, or recovery outside its bounded appearance history. Essential verification can reject correct matches under low parallax and can accept an incorrect repeated structure if geometry is degenerate. The adversarial test explicitly injects a candidate with 80 matches, 70 inliers, valid rotation, and translation direction; the output remains lost/null and the authoritative pose is unchanged. The strongest practical additions are wheel/IMU scale, metric-map PnP for retrieved landmarks, semantic masking of moving vehicles, a trained VLAD index, and pose-graph optimization. Those preserve the central rule demonstrated here: learned appearance proposes; independently verified **metric** geometry disposes.
