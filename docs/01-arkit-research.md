# ARKit and iPhone 16 Pro research

Research date: 2026-08-11. The implementation target is an iPhone 16 Pro running iOS 18 or later. Claims below favor Apple primary sources; numerical performance claims not published by Apple are explicitly treated as measurements to collect, not guarantees.

## Decision summary

`ARWorldTrackingConfiguration` plus `ARWorldMap` is the correct first implementation. It already provides the full operational loop—visual-inertial 6DoF tracking, LiDAR depth, scene reconstruction, map snapshotting, secure local serialization, and later relocalization through `initialWorldMap`—without internet or external hardware.

It is not sufficient as a guaranteed whole-house localization product. `ARWorldMap` is opaque, offers no public descriptor/keyframe database, exposes no quantitative relocalization confidence, offers no documented building-size guarantee, and can remain in `.relocalizing` indefinitely. Apple says persistence reliability depends strongly on consistent lighting and environmental features. Therefore:

1. Build and measure the ARWorldMap pipeline first.
2. Design storage and pose APIs so a custom relocalizer can be added without changing the UI or map coordinate contract.
3. Add the custom layer only if a real-device test matrix shows that ARKit fails the arbitrary-room requirement too often.

## 1. What the iPhone and ARKit already provide

### Hardware

The iPhone 16 Pro has an A18 Pro SoC, a rear LiDAR Scanner, a 48 MP Fusion camera, a 48 MP ultrawide camera, IMU-class motion sensors, and a magnetometer. The app must still test API support at runtime instead of assuming a model name. Apple does not publish a usable per-process memory budget, and iOS can terminate an app under memory pressure.

Source: [iPhone 16 Pro technical specifications](https://support.apple.com/en-us/121031).

### Six-degree-of-freedom tracking

`ARWorldTrackingConfiguration` tracks roll, pitch, yaw, and XYZ translation. ARKit owns sensor synchronization and visual-inertial fusion. Each `ARFrame` supplies `ARCamera.transform`, camera intrinsics, tracking state, captured image, timestamps, and optional depth.

Sources: [ARWorldTrackingConfiguration](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration), [ARCamera](https://developer.apple.com/documentation/arkit/arcamera).

### LiDAR depth

Enabling `.sceneDepth` and/or `.smoothedSceneDepth` asks ARKit for an `ARDepthData` depth map and confidence map associated with the rear camera image. Raw scene depth is preferred for geometry and geometric verification; smoothed depth is useful for visualization but introduces temporal smoothing.

Sources: [`sceneDepth`](https://developer.apple.com/documentation/arkit/arframe/scenedepth), [Displaying a point cloud using scene depth](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth).

### Scene reconstruction and planes

On supported LiDAR devices, `.mesh` or `.meshWithClassification` produces updating `ARMeshAnchor` chunks. Horizontal and vertical plane detection can improve/smooth reconstructed planar surfaces. Mesh anchors are useful for visualization, occlusion, collision, and a future ICP check; the mesh is not itself ARKit's public relocalization index.

Sources: [`sceneReconstruction`](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction), [`ARMeshAnchor`](https://developer.apple.com/documentation/arkit/armeshanchor).

### Visual feature points

`ARFrame.rawFeaturePoints` exposes a coarse debug point cloud. A saved `ARWorldMap` also exposes coarse feature points, its center, extent, and anchors. Apple explicitly does not guarantee feature point count, arrangement, or stability between frames or OS releases. The public points do not include the image descriptors and observation graph required to build a robust independent relocalizer.

Sources: [`ARFrame.rawFeaturePoints`](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints), [`ARWorldMap.rawFeaturePoints`](https://developer.apple.com/documentation/arkit/arworldmap/rawfeaturepoints), [`ARWorldMap`](https://developer.apple.com/documentation/arkit/arworldmap).

### Persistent world maps and anchors

`ARSession.getCurrentWorldMap` produces an `NSSecureCoding` snapshot of ARKit's spatial mapping state and anchors. The archive survives process termination. Loading it into `ARWorldTrackingConfiguration.initialWorldMap` asks ARKit to reconcile the new observations with the old map. On success, tracking becomes `.normal` and restored anchors share the saved coordinate system.

Sources: [Saving and loading world data](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data), [`initialWorldMap`](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap).

### Camera selection limitation

World tracking gives the app ARKit's synchronized `capturedImage`; it is not a general multi-camera capture session. The proof of concept should use ARKit's managed rear-camera stream rather than attempting to run independent wide and ultrawide `AVCaptureSession` pipelines beside it. Additional lenses are not required for the first relocalization pipeline.

### RoomPlan is complementary, not the localization backend

RoomPlan can scan and merge multiple rooms into a `CapturedStructure`, which is useful for semantic floor-plan output. Its output is a structured model/asset, not a documented arbitrary-start 6DoF relocalization database. Adding it would duplicate capture work before the core persistent-pose loop is proven.

Sources: [Scanning the rooms of a single structure](https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure), [`CapturedStructure`](https://developer.apple.com/documentation/roomplan/capturedstructure).

## 2. Is ARWorldMap sufficient?

### Sufficient for the first end-to-end proof of concept

Yes. It directly supports:

- persistent local maps across app restarts;
- a stable coordinate system and saved anchors;
- on-device 6DoF relocalization and tracking;
- recovery attempts after interruptions;
- no GPS, network, server, or external sensor;
- coarse map extent/feature diagnostics.

### Not sufficient as a hard guarantee for the final requirement

No public Apple API promises:

- global recognition from every arbitrary room/viewpoint in a large house;
- a maximum supported floor area or trajectory length;
- a relocalization deadline;
- a probability/covariance for the reported pose;
- map merging, map editing, descriptor export, or a queryable keyframe graph;
- robustness across major lighting, furniture, wall-texture, or OS-version changes.

Apple states that failed reconciliation can remain `.relocalizing` indefinitely, and recommends guiding the person back to an area/view observed when recording. That is a best-effort resume contract, not a place-recognition SLA.

Source: [Managing session life cycle and tracking quality](https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality).

## 3. Is a custom visual/LiDAR relocalizer necessary?

It is **not yet justified for Phase 1**. Implementing SLAM from scratch would discard Apple's calibrated, hardware-optimized VIO and map machinery before measuring it.

It becomes necessary if device testing demonstrates any of these release-blocking failures:

- arbitrary-room relocalization recall is below the product target;
- time-to-localize is unacceptably long or frequently indefinite;
- perceptual aliasing produces wrong-room poses without detectable warning;
- maps routinely fail after expected lighting/furniture changes;
- multiple ARWorldMaps are needed and the app must choose among them automatically.

The custom component should be a **global relocalization sidecar**, not a replacement for frame-to-frame VIO. It proposes and geometrically verifies `T_map_camera`; ARKit continues high-rate local tracking after that alignment.

## 4. Expected accuracy and limitations

Apple publishes state categories, not a meter/degree error bound. Any exact accuracy promise would be invented. Initial acceptance targets for testing—not guarantees—are:

| Situation | Initial engineering target |
| --- | --- |
| Good-texture, unchanged indoor scene | relocalize in ≤10 s for at least 90% of mapped test starts |
| Position repeatability after success | ≤0.15 m median, ≤0.40 m p95 against measured checkpoints |
| Orientation repeatability | ≤3° median, ≤8° p95 |
| Wrong confident room | 0 accepted occurrences; ambiguous results must remain low confidence |
| Temporary interruption | recover in ≤10 s after revisiting mapped visual content |

These must be measured with physical checkpoints and repeated runs. Likely failure modes are blank/reflective walls, darkness or glare, repeated corridors/doors, motion blur, occlusion, large furniture changes, mirrors/glass, map drift on long loops, thermal throttling, and insufficiently overlapping viewpoints.

The magnetometer and GPS are intentionally excluded from the map-frame contract. Magnetic indoor yaw can be distorted, and GPS is not reliable indoors.

## 5. Computational, thermal, storage, and memory constraints

- ARKit, scene reconstruction, depth delivery, rendering, and image feature work compete for GPU, neural, memory, and thermal budgets.
- Do not retain full-resolution camera frames continuously. `CVPixelBuffer` objects should be consumed and released promptly.
- Do not save every depth frame. Future keyframes should be selected by motion/coverage and compressed/downsampled.
- Keep live visualization bounded: voxel/downsample points, cap the pose trail, and let ARKit manage mesh anchor lifetimes.
- Archive only one `ARWorldMap` snapshot per saved revision, written atomically.
- Use `ProcessInfo.thermalState`, memory warnings, and measured package sizes to adapt optional work.
- Run descriptor extraction and compression off the main thread and never block `ARSessionDelegate` callbacks.
- The app must be profiled on the target phone; Simulator and Mac measurements are not substitutes.

Recommended starting budgets for the proof of concept are operational guardrails, not device limits: under 500 MB resident memory during a normal scan, under 250 MB per saved house package, a capped 2,000-point UI overview, and no stored video stream.
