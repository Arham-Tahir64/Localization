# Architecture, map format, frames, and relocalization

## Recommended architecture

```text
SwiftUI screens
    │
    ├── ARSessionController ── ARKit world tracking + LiDAR + mesh
    │       │
    │       ├── Mapping diagnostics / bounded overview points
    │       ├── Pose + tracking/relocalization state
    │       └── Map snapshot / reload
    │
    ├── MapStore ── atomic local map packages
    │
    └── RelocalizationBackend
            ├── ARWorldMapBackend (implemented first)
            └── KeyframeDepthBackend (future, only if tests require it)
```

The public pose contract is backend-independent:

```swift
PoseEstimate(
    mapFromCamera: simd_float4x4,
    state: awaiting | relocalizing | tracking | limited | failed,
    confidence: unavailable | low | medium | high,
    source: arWorldMap | customVisualDepth
)
```

The displayed confidence is a conservative application band. ARKit does not expose pose covariance or relocalization probability, so the UI must never label it as statistical accuracy.

## Map package

Each map is a directory in Application Support:

```text
Maps/<UUID>/
├── metadata.json
├── worldmap.arexperience
└── preview.jpg
```

`metadata.json` contains:

- schema version and UUID;
- user-facing name and timestamps;
- iOS/app version;
- world-map center and extent in meters;
- saved raw-feature count;
- whether LiDAR depth and mesh were available;
- map format/backend identifier;
- optional capture notes and validation statistics in later schemas.

`worldmap.arexperience` is a secure-keyed archive of `ARWorldMap`. It is the only data required by the initial relocalizer. `preview.jpg` is a human guide, not localization input.

Do **not** duplicate the full mesh, images, depth stream, or video merely because they are available. If a custom backend is justified, add a versioned sidecar:

```text
custom/
├── keyframes.json
├── images/<id>.heic
├── depths/<id>.bin.lzfse
├── descriptors.bin
├── landmarks.bin
└── geometry.bin
```

Keyframes are selected for coverage and baseline, not at camera frame rate. Each stores `T_map_camera`, timestamp, intrinsics, image orientation/size, a compact image, valid downsampled depth with confidence, global retrieval descriptor, local feature descriptors/keypoints, and 3D landmark associations.

## Coordinate-frame contract

### Notation

`T_A_B` is a 4×4 rigid transform that maps homogeneous coordinates **from frame B into frame A**:

```text
p_A = T_A_B · p_B
T_B_A = inverse(T_A_B)
```

Matrices use `simd_float4x4` column-vector convention. Translation is the fourth column. All frames are right-handed and distances are meters.

### Frames

**C — ARKit camera frame.** This is the camera coordinate space represented by `ARCamera.transform`. Apple defines it independent of the current UIKit device orientation. The camera looks along negative Z; X/Y follow ARKit's documented landscape-left camera convention.

**W — current ARKit world frame.** With `.gravity` alignment, Y is opposite gravity at session initialization; X/Z form the horizontal plane. Its origin is established when the current `ARSession` starts. Magnetic north is not part of the contract.

**M — persistent map frame.** During mapping, M is defined to equal W at map creation. A named identity `ARAnchor` records the map origin. M never changes when the package is reopened.

**D — depth-image optical frame.** Pixels have origin at the depth image's top-left, +u right and +v down; depth is positive forward range. `sceneDepth` is associated with the captured rear-camera image, but depth/image resolution and orientation differ. Conversion must use the frame's intrinsics scaled to depth resolution and the capture/display orientation. Code must not assume raw depth pixels are already UIKit pixels or blindly treat D as C.

**P — phone body frame (optional).** ARKit publicly reports the camera pose, which is what the app exposes as “phone pose.” A metrology-grade body-center pose would require a documented/calibrated camera-to-body extrinsic that this proof of concept does not invent.

### ARKit mapping session

ARKit returns:

```text
T_W_C = frame.camera.transform
T_C_W = inverse(T_W_C) = frame.camera.viewMatrix(...) modulo display orientation
```

Because mapping defines `M := W`:

```text
T_M_W = I
T_M_C = T_W_C
```

### ARWorldMap relocalized session

Before relocalization succeeds, no pose is published in M. The current local `T_W_C` may exist but is not yet aligned with the saved map and must not be presented as a map pose.

After ARKit successfully reconciles `initialWorldMap`, the session world coordinates and restored anchors are expressed in the saved map coordinate system. For the ARWorldMap backend:

```text
T_M_W = I
T_M_C = T_W_C
```

The identity map-origin anchor is an invariant/check, not an extra alignment calculation.

### Future custom relocalizer

If a custom solver estimates the current global pose `T_M_C*` while ARKit simultaneously provides local `T_W_C*`, compute the fixed alignment:

```text
T_M_W = T_M_C* · inverse(T_W_C*)
```

For each later frame:

```text
T_M_C(t) = T_M_W · T_W_C(t)
T_C_M(t) = inverse(T_M_C(t))
```

Re-estimation should be gated and smoothed; a single weak candidate must never jump `T_M_W`.

### Depth unprojection rule

For a depth pixel `(u, v)` with positive range `z`, first scale camera intrinsics to the depth buffer dimensions. Unproject it in the depth optical convention, apply the tested orientation/extrinsic transform `T_C_D`, then place it in map space:

```text
p_D = z · K_D⁻¹ · [u, v, 1]ᵀ
p_M = T_M_C · T_C_D · p_D
```

The exact sign/orientation adaptation belongs in one tested utility because ARKit camera axes and image pixel axes differ. Validate it by projecting depth points onto known mesh/camera surfaces; do not scatter axis flips through rendering code.

## ARWorldMap relocalization algorithm (implemented first)

1. Read and secure-unarchive the selected `ARWorldMap` off the UI path.
2. Validate schema, archive presence, and device capabilities.
3. Configure world tracking with `.gravity`, planes, supported scene reconstruction, and supported scene-depth semantics.
4. Set `configuration.initialWorldMap` and run with `.resetTracking` and `.removeExistingAnchors`.
5. Publish `awaiting/relocalizing` only; withhold map pose.
6. Encourage slow translation and rotation through previously mapped views. Show the saved visual guide and a timeout/retry action.
7. Accept initial alignment only after ARKit reports `.normal` following the relocalization attempt and the saved map-origin anchor is restored.
8. Publish `T_M_C = frame.camera.transform`; raise the application confidence band only after sustained normal tracking.
9. On `.limited`, interruption, or failure, retain the last pose only as stale, mark confidence low/unavailable, and let ARKit attempt relocalization.
10. If the timeout expires, report failure/low confidence rather than silently starting an unrelated world frame.

## Future custom visual/LiDAR algorithm

This is a fallback design, not part of the first build:

1. Generate an on-device global image feature print for the live frame and retrieve a small set of keyframes. Vision feature prints can rank image similarity, but are not sufficient for 6DoF geometry by themselves.
2. Match local features between the live frame and candidate keyframes. Candidate implementations are an on-device Core ML local-feature network or a carefully packaged C++ feature matcher.
3. Recover 2D↔3D correspondences from keyframe depth/landmarks.
4. Estimate `T_M_C` using PnP + RANSAC; reject solutions with too few inliers, poor spatial distribution, high reprojection error, or implausible gravity disagreement.
5. Independently verify candidate geometry by aligning the current LiDAR/depth cloud to stored local geometry and measuring overlap/residual. Repeated rooms require especially strict verification.
6. Compute `T_M_W` from the accepted global pose and current ARKit local pose.
7. Continue tracking using ARKit VIO at frame rate. Run global checks opportunistically and after tracking loss, not on every frame.
8. Confidence combines retrieval margin, inlier count/distribution, reprojection error, depth residual/overlap, tracking state, temporal consistency, and agreement across multiple frames.
9. If candidates disagree or verification is weak, return “not localized.” A missing pose is safer than a convincing wrong-room pose.

Source for optional retrieval primitive: [`VNFeaturePrintObservation`](https://developer.apple.com/documentation/vision/vnfeatureprintobservation).
