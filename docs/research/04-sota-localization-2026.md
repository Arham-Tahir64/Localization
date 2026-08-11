# Persistent iPhone mapping and relocalization: research synthesis

**Research cut-off:** 2026-08-11. This note distinguishes what is documented
by Apple or a cited paper from a proposed implementation. In particular, it
does **not** turn benchmark results from a different device, dataset, or GPU
into an accuracy promise for an iPhone 16 Pro.

## Decision in one sentence

Keep `ARWorldMap` + ARKit world tracking as the default persistent-map and
continuous-tracking path. When a trusted server is reachable, use a
**coarse-to-fine server relocalizer** (retrieval -> verified 2D-3D PnP ->
depth/mesh verification -> a fixed map-to-current-AR-session transform),
augmented by timestamped ARKit VIO telemetry. Retain the equivalent compact
on-device pipeline as a privacy/offline fallback. This avoids replacing
ARKit's proprietary visual-inertial tracker while supplying the explicit
global-recovery mechanism that `ARWorldMap` does not guarantee.

## What ARKit can and cannot be the map

`ARWorldMap` is the right baseline, not a disposable demo feature. Apple's
[`initialWorldMap`](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap)
documentation says a saved map contains ARKit's awareness of the space and the
app's anchors. A session started with it begins in limited/relocalizing state;
on success, normal tracking means the current coordinate system and anchors
match the saved one. That is precisely the desired fast path: saved map
coordinate frame equals the tracked frame after relocalization.

It is not a public, deterministic whole-house localization database. Apple
also states that a session remains relocalizing indefinitely if it cannot
reconcile the saved map and the current environment. Apple does not promise
that it will search every room from an arbitrary start, disclose the
descriptors/index used internally, or expose an API to seed it with a custom
6-DoF pose. Treat `ARCamera.trackingState == .normal` after an initial map as
strong ARKit evidence, but not as a calibrated confidence score or a
programmatic proof that arbitrary-start recall is complete.

LiDAR provides valuable, independent geometry but should not replace vision.
With `.sceneDepth`, ARKit produces an `ARDepthData` depth map and a confidence
map; each depth pixel is a distance from the rear-camera plane in metres
([Apple](https://developer.apple.com/documentation/arkit/ardepthdata)). Scene
reconstruction yields incrementally refined `ARMeshAnchor` geometry; Apple
explicitly cautions that mesh updates are not real-time change reports
([ARMeshAnchor](https://developer.apple.com/documentation/arkit/armeshanchor)).
Consequently, depth/mesh is excellent for local pose verification and map
geometry, but not a reliable sole detector of moved furniture.

## Candidate techniques and product decision

| Candidate | What it contributes | Deployment suitability | Decision |
| --- | --- | --- | --- |
| ARKit `ARWorldMap` | Integrated visual-inertial tracking, saved spatial awareness, anchors, immediate continuous tracking after success | Native and lowest risk | **Ship as primary.** |
| Apple Vision Feature Print | On-device image-similarity embedding and distance comparison; Apple recommends precomputing catalog prints and thresholding/ranking them ([WWDC26](https://developer.apple.com/videos/play/wwdc2026/297/)) | Excellent coarse retrieval, no extra model | **First fallback retrieval implementation.** It is not geometric verification. |
| ORB + descriptor matching + PnP | Classical keypoints/descriptors, cheap implementation, then metric 6-DoF from 2D-3D correspondences | Good in C++/OpenCV; weaker under strong appearance change | **Pragmatic fallback v1** if learned-model integration slips. |
| Open SuperPoint + LightGlue + PnP | Learned local points plus adaptive sparse matching; LightGlue is designed to reduce work for easy pairs ([paper](https://openaccess.thecvf.com/content/ICCV2023/html/Lindenberger_LightGlue_Local_Feature_Matching_at_Light_Speed_ICCV_2023_paper.html)) | Potentially good, but Core ML conversion, memory, and device profiling must be proven | **Accuracy-focused v2**, evaluated against ORB before enabling by default. |
| Dense transformer matching (LoFTR/MASt3R family) | Can improve difficult wide-baseline matching; MASt3R reports strong research results ([paper](https://arxiv.org/abs/2406.09756)) | High implementation/thermal risk. Even Speedy MASt3R reports A40-GPU, not iPhone, timing ([paper](https://arxiv.org/abs/2503.10017)) | **Research only**, not a house-map runtime dependency. |
| LiDAR depth-to-map ICP/GICP | Metric residual check/refinement once a good initial pose exists | Feasible for a small local submap, not a global initializer | **Use after PnP, never as the only arbitrary-start search.** |
| Server HLoc/COLMAP-style map and localizer | A mature hierarchical SfM/localization reference pipeline, large indices and GPU inference | Strongest practical connected option; server must protect private home imagery | **Preferred connected accuracy path.** |
| Server 3DGS/NeRF pose refinement | Differentiable/rendered appearance can refine a good seed | GPU-heavy and sensitive to map/appearance and seed quality | **Optional verifier/research path, never the global-only localizer.** |
| Fully custom visual-inertial SLAM / global pose graph | Full control of map internals/loop closure | Very high risk; would duplicate ARKit and conflict with its saved coordinate frame | **Do not replace ARKit in this project.** |

The hierarchical pipeline is established rather than speculative: the
[Hierarchical Localization](https://github.com/cvg/Hierarchical-Localization)
toolbox describes retrieval, local feature matching, and localization, and
includes indoor (InLoc) and other localization pipelines. It is a valuable
offline research/evaluation reference, **not** an iOS runtime: it is a Python /
PyTorch toolbox and its reconstruction path relies on desktop-oriented tools.

## Recommended architecture

### 1. Retain the current ARKit baseline

During mapping, keep the accepted `ARWorldMap`, named anchors, ARKit poses,
scene mesh and selected high-confidence depth samples. Define the saved ARKit
world as `M` (the immutable house-map frame). Do not run a pose-graph optimizer
that silently moves `M`: doing so would make the custom map disagree with the
unmodifiable `ARWorldMap` frame. A diagnostic keyframe graph is useful, but its
constraints should be used to reject bad keyframes or flag map quality, not to
rewrite the baseline coordinate system.

On reopen, first run `ARWorldTrackingConfiguration(initialWorldMap:)`. If
ARKit becomes normal and passes the app's temporal stability gate, use its
native poses directly (`T_M_C = T_W_C`, because `W == M` after successful
ARWorldMap relocalization). Do not spend battery running the custom pipeline
continuously in this state.

### 2. Store a compact, explicit fallback index while mapping

Capture a **quality-gated keyframe**, not every video frame. Gate on ARKit
normal tracking, translation/rotation novelty, blur/exposure, texture, enough
high-confidence depth, and coverage of a previously underrepresented area.
For each keyframe retain:

* `keyframeID`, `T_M_C`, timestamp, wide-camera intrinsics, image orientation,
  image size, and a capture/OS/model-version record.
* A downscaled, privacy-local reference image (or an encrypted app-local image
  if the product's privacy policy requires it) so descriptors can be rebuilt
  after an OS/model revision.
* A **global retrieval descriptor**. Start with a Vision Feature Print. Pin and
  record the Vision request revision; Apple notes request revisions can change
  behaviour across SDKs ([Vision revision documentation](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequestrevision1)).
  Do not compare feature prints produced by incompatible revisions without a
  migration test.
* Local keypoints, scores, descriptors, and the 3D map point associated with
  each retained point. Build a landmark by back-projecting only aligned,
  high-confidence depth and transforming it with `T_M_C`; merge observations in
  a small voxel/neighbourhood only when descriptor agreement and viewing-angle
  checks support it. Keep observation count, normal/uncertainty, and a
  staticness score rather than treating every depth return as permanent.
* A small local geometric submap around the keyframe: downsampled static mesh
  triangles or surfels with normals. The scene mesh is an approximate shape,
  and enabling it requires a support check
  ([Apple](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction)); it is not a precision survey mesh.

Depth-image association deserves an explicit calibration test. `sceneDepth`
pixels describe regions of the camera image, but depth and captured-image
buffers can have different dimensions/orientations. Preserve the exact ARFrame
intrinsics and image/depth dimensions, apply the documented image transform,
and validate reprojected saved points against the reference image. Never assume
that a pixel index can be copied between buffers without scaling/orientation
handling.

Use an append-only package containing an index version and per-component model
versions. Make raw images optional; do not discard them until descriptor
migration has been validated. An indicative descriptor-only budget is easy to
calculate: 1,000 descriptors of 256 FP16 values cost about 512 KB before
keypoint/landmark metadata. Actual image and mesh sizes are content-dependent;
measure package size on representative homes instead of setting a fictional
universal cap.

### 3. Fallback relocalization state machine

Run this only after a bounded ARWorldMap attempt has not succeeded, and rate
limit it while the user moves slowly enough to avoid blur.

1. **Coarse place retrieval.** Make a current global descriptor and rank saved
   keyframes. Vision Feature Print is an implementation-friendly first pass;
   its purpose is to reduce hundreds of keyframes to a small candidate set, not
   to return a pose. A learned VPR model such as
   [MixVPR](https://arxiv.org/abs/2303.02190) is a future candidate when it
   demonstrates better *home-specific* recall at acceptable on-device latency.
   Its published benchmark recall is not an iPhone-house accuracy claim.
2. **Local correspondence.** For each candidate, match query local features to
   its 2D-3D landmarks. Start with mutual/ratio-tested ORB matches for the
   simpler implementation. For the accuracy track, evaluate an exported,
   fixed-shape open SuperPoint + LightGlue model at a bounded resolution and
   number of keypoints. The literature supports the design: SuperPoint learns
   repeatable local features ([paper](https://arxiv.org/abs/1712.07629));
   SuperGlue jointly matches and rejects non-matchable features
   ([paper](https://openaccess.thecvf.com/content_CVPR_2020/html/Sarlin_SuperGlue_Learning_Feature_Matching_With_Graph_Neural_Networks_CVPR_2020_paper.html));
   LightGlue is the lower-latency successor candidate.
3. **Metric pose.** Estimate `T_M_C` with calibrated 2D-3D PnP in a robust
   consensus loop. OpenCV's
   [`solvePnPRansac`](https://docs.opencv.org/4.x/d9/d0c/group__calib3d.html)
   is a suitable initial production primitive: it estimates pose from known
   3D-2D correspondences and returns inliers. Prefer a current USAC/MAGSAC
   configuration if the chosen iOS build exposes it, then refine the accepted
   pose with all inliers. The correct camera intrinsics and pixel orientation
   are mandatory.
4. **Geometric verification/refinement.** Select only the local submap(s) near
   the PnP pose. Back-project current high-confidence depth; robustly align it
   to saved static surfels/mesh using point-to-plane ICP or GICP, with a robust
   loss and a multi-resolution pyramid. ICP is a local method: the PCL
   registration documentation notes that its main group requires an initial
   transformation guess, whereas guess-free alternatives are generally slower
   and less accurate ([PCL](https://pointclouds.org/documentation/group__registration.html)).
   Reject, rather than accept, a divergent, low-overlap, or geometrically
   degenerate refinement (for example a largely single flat wall).
5. **Temporal confirmation.** Require independently captured frames to agree
   in map pose before declaring localized. Score the chosen candidate by
   retrieval margin, 2D-3D inlier count/ratio and spatial spread, median and
   tail reprojection error, PnP conditioning, depth overlap/residual, and
   agreement across frames. These scores must be calibrated from labelled
   house walks; they are inputs to an acceptance policy, not a magic confidence
   percentage.
6. **Bridge to ARKit tracking.** At the accepted instant, ARKit still has a
   current session frame `W` and camera pose `T_W_C`. Compute
   `T_M_W = T_M_C * inverse(T_W_C)`. Then continuously report
   `T_M_C(t) = T_M_W * T_W_C(t)` while ARKit is normally tracking. This leaves
   ARKit responsible for high-rate visual-inertial tracking while the app owns
   the persistent house transform.
7. **Recovery.** When ARKit becomes limited, freeze the last accepted map pose
   as a labelled estimate (not a current truth), restart bounded retrieval only
   after enough visual change, and demand the same geometric/temporal checks.
   Do not repeatedly reset ARKit and discard a potentially good local track.

### 4. Change robustness and abstention

The highest-accuracy system is one that refuses an unsupported pose. Repeated
walls, mirrors, blank surfaces, opened/closed doors, lighting changes, and
moved furniture create plausible but wrong matches. Long-term localization
research specifically finds that semantic consistency can downweight erroneous
correspondences under appearance changes
([Toft et al., ECCV 2018](https://openaccess.thecvf.com/content_ECCV_2018/html/Carl_Toft_Semantic_Match_Consistency_ECCV_2018_paper.html)).

Implement the product version conservatively before adding a semantic model:

* Maintain landmark observation history and exclude candidate matches on
  low-staticness classes/regions (screens, windows, people, movable furniture)
  from the *acceptance* set. They may remain weak retrieval cues.
* Accept only when visual PnP **and** depth geometry agree, except when depth
  coverage is genuinely unavailable; in that case label the result
  visual-only/lower confidence rather than silently applying the same score.
* Test candidate distinctiveness (best-vs-second retrieval/match score) and
  geometric diversity (not all inliers on one plane/small image patch).
* Calibrate acceptance thresholds on held-out walks with intentional changes.
  For every candidate policy, report false-localization rate and abstention
  rate as well as recall. A lower recall policy may be the correct choice if it
  sharply reduces confident false poses.
* Keep multiple mapping-time observations of stable architecture (wall corners,
  door frames, permanent fixtures) across lighting/viewpoint changes. Add a
  controlled “refresh map” workflow rather than mutating the trusted map after
  a single uncertain session.

## Connected, server-assisted localization

Server compute changes the resource budget, not the geometry rules. The server
must return a timestamped, verified pose in a documented map frame; the iPhone
then bridges that pose into its live ARKit session and continues tracking
locally. Uploading undifferentiated video and trusting a server-side image
classifier is not a high-accuracy localization design.

### Three stream contracts

| Contract | Server has | What it can reliably attempt | Relative risk/recommendation |
| --- | --- | --- | --- |
| **A. RGB video only** | Compressed frames and transport timestamps | Global retrieval, 2D-2D matching, server SfM/VSLAM, and—if the map has metric 3D landmarks—PnP after recovered/calibrated intrinsics | Lowest client integration, but unknown/changing camera model, rolling-shutter/compression artifacts, and timestamp ambiguity reduce metric reliability. Use only as a compatibility mode. |
| **B. RGB + calibrated frame metadata + ARKit VIO/IMU telemetry** | A frame ID, ARFrame capture time, intrinsics, image geometry/orientation, ARKit camera pose/tracking state, and synchronized ARKit-VIO / optional raw motion data | All of A plus pose-prior guided retrieval, visual-inertial consistency checks, easier metric alignment, stale-result handoff, and higher-rate client tracking | **Recommended default connected contract.** ARKit pose is a prior, not ground truth and must not be used to bypass visual/geometric verification. |
| **C. RGB + B + selected LiDAR depth / mesh** | High-confidence aligned depth, depth confidence, local mesh/surfel deltas, and their calibration/time metadata | All of B plus metric RGB-D mapping, local depth/mesh registration, occlusion/overlap checks, and robust rejection of visual aliases | **Recommended high-accuracy contract.** Stream selected keyframes/regions, not every raw point or mesh update. |

Apple exposes the essential timestamps and geometry: `ARFrame.timestamp` is the
camera-frame capture time ([Apple](https://developer.apple.com/documentation/arkit/arframe/timestamp))
and `ARCamera.transform` is the camera pose in ARKit world coordinates; Apple
documents ARKit world as right-handed
([Apple](https://developer.apple.com/documentation/arkit/arcamera/transform)).
Use those values per observation, rather than the video encoder's output time,
as the authority for geometric association.

### Server map building

For a new or refreshed map, upload only mapping-session keyframes selected by
the same quality gates described above, plus camera intrinsics/extrinsics and
optional depth. Keep the original ARKit map package for client fallback, and
build a separate server map artifact with an immutable `mapVersion`.

1. **RGB / RGB-D reconstruction.** Use
   [COLMAP](https://github.com/colmap/colmap) as the baseline server
   reconstruction tool. It is a maintained general-purpose SfM and MVS system,
   now under a BSD license. Supply ARKit poses as soft priors/initial values,
   not unquestioned measurements; preserve known intrinsics rather than
   needlessly re-estimating a mobile camera. Run global bundle adjustment and
   retain a sparse, descriptor-bearing 3D point map for localization. Fuse
   depth only after reprojection/time consistency checks; it establishes metric
   scale and supplies dense local geometry, but poor-confidence depth must not
   dominate the visual model.
2. **Metric map-frame alignment.** An RGB-only SfM reconstruction has an
   arbitrary similarity frame `S`. Estimate a robust Sim(3) from corresponding
   ARKit/depth metric poses or landmarks to establish `T_M_S` once. Store the
   transform, inlier statistics, units, source map version, and convention
   explicitly. If an RGB-D or ARKit-metric reconstruction directly uses `M`,
   still record that decision rather than relying on an implicit convention.
3. **Localization index.** Store global keyframe embeddings in an exact or
   approximate nearest-neighbour index. Faiss is a maintained MIT-licensed
   dense-vector similarity library with CPU and optional GPU implementations
   ([repository](https://github.com/facebookresearch/faiss)); it offers
   deliberate time/quality/memory index trade-offs. Store local descriptors,
   image observations, 3D landmark tracks, visibility/semantic-staticness, and
   a spatial partition into local geometric submaps.
4. **Map quality report.** Before publishing a map version, replay held-out
   mapping frames and independent revisit walks. Reject sparse/disconnected
   components, weakly constrained geometry, duplicated rooms, and maps whose
   verified localizer cannot recover. A pretty mesh or Gaussian splat is not
   evidence that the map localizes.

[HLoc](https://github.com/cvg/Hierarchical-Localization) is the appropriate
pipeline reference: it documents feature extraction, covisibility/retrieval,
matching, SfM, and localization; it also supports InLoc, where LiDAR scans can
replace the standard SfM-model step. Use it to make a repeatable server
baseline and an evaluation oracle, then replace individual pieces only with
measured improvements. It is Apache-2.0 at repository level, but all model and
submodule licences must still be audited.

Avoid making a custom server SLAM stack the product's first dependency.
[ORB-SLAM3](https://github.com/UZ-SLAMLab/ORB_SLAM3) is an important research
reference for visual, visual-inertial, and RGB-D SLAM, but its repository
licence is [GPLv3](https://github.com/UZ-SLAMLab/ORB_SLAM3/blob/master/License-gplv3.txt).
It is useful for benchmark comparison or a separately
licenced deployment, not a safe default component for a closed-source client or
service without legal review.

### Online server relocalization

For every selected query frame, the server should perform the following
bounded work. It should return an explicit `unlocalized` result when a gate
fails; it must never return the top retrieval result as a 6-DoF pose.

1. Decode the image and bind it to the submitted `frameID`, capture timestamp,
   calibrated intrinsics, orientation, and map version. Reject orphaned or
   incompatible metadata before feature extraction.
2. Retrieve a small set of candidate keyframes/regions by global embedding.
   Contract B may also retrieve around the client VIO prior while retaining a
   global-search escape hatch for VIO drift or an arbitrary start.
3. Extract local query features and match against the selected 3D landmark
   observations. A high-capacity server can evaluate several legally usable
   feature/matcher pairs. The initial production comparison should include
   ORB, open SuperPoint + LightGlue, and the already documented HLoc reference;
   select on held-out false-accept and latency results, not paper rankings.
4. Estimate `T_M_C` with calibrated robust PnP, robustly refine with
   reprojection-error minimization, and require inlier count, image/3D spatial
   distribution, candidate-margin, and pose-conditioning gates. OpenCV's
   `solvePnPRansac` remains a suitable primitive, while the server can use a
   stronger robust estimator where it has been validated.
5. For contract C, load only nearby saved surfels/mesh and perform robust
   point-to-plane/GICP refinement from the PnP pose. Require sufficient
   overlap, non-degenerate geometry, and residual improvement. Do not use ICP
   as a global search or accept a pose merely because a flat wall aligns.
6. Confirm with a short sequence of independent query frames and, for B/C,
   compare the relative pose changes with VIO. A server pose with a large
   residual or a disagreement with the telemetry is a rejection signal, not a
   reason to average incompatible transforms.
7. Return `{mapVersion, frameID, captureTime, T_M_C, covariance/quality
   diagnostics, verificationMode, expiry}` signed or authenticated by the
   service. The result is valid only for the frame it names.

### Time and coordinate synchronisation

Use active transforms `T_A_B` that map a point expressed in frame `B` into
frame `A`. Let `C_i` be the rear-camera frame of a submitted image, `W_i` the
ARKit session world at its capture time, and `M` the immutable persistent map.
ARKit reports `T_Wi_Ci`; the server estimates `T_M_Ci` for exactly the same
frame ID. The client computes:

```text
T_M_Wi = T_M_Ci · inverse(T_Wi_Ci)
T_M_C(now) = T_M_Wi · T_Wnow_Cnow
```

Thus server latency does not make a good answer stale: it anchors the ARKit
session at the capture instant, then current local VIO advances the pose. If
ARKit has reset/restarted between capture and response, do **not** apply the
result across the reset; submit a fresh query or use a separately recorded
world-to-world bridge that has passed verification.

Every packet needs at minimum: monotonic capture clock/timebase identifier,
frame ID, AR session/run ID, `T_W_C`, tracking state, 3x3 intrinsics in the
pixel coordinate system actually encoded, encoded-image dimensions/crop,
orientation, camera selection, exposure/rolling-shutter metadata when
available, and depth/mesh dimensions and confidence semantics when used. If
raw IMU is needed, transmit timestamped accelerometer/gyroscope samples from
Core Motion ([`CMMotionManager`](https://developer.apple.com/documentation/coremotion/cmmotionmanager))
in the same declared timebase.

Do not assume raw Core Motion samples are already calibrated in the AR camera
frame or replicate ARKit's internal VIO solely from public camera poses. Treat
the ARKit camera pose as the usable VIO prior. Use raw IMU initially for
motion/quality diagnostics and future offline experiments; introduce a
server-side VIO fusion only after camera-to-IMU extrinsics, clock alignment,
bias handling, and replay evaluation are explicitly validated.
Maintain an explicit affine client-clock-to-server-receive diagnostic only for
latency monitoring; geometric matching must use capture-frame IDs, not inferred
network arrival time. Test association under deliberately reordered, dropped,
and delayed packets.

### Transport, privacy, and failure behaviour

Use separate media and metadata paths. WebRTC is a reasonable live-video
transport because the W3C specification defines media plus generic data and
its data channel can be configured for reliable or bounded-unreliable delivery
([W3C WebRTC](https://www.w3.org/TR/webrtc/)). In a native implementation, an
equivalent authenticated low-latency video transport is acceptable. Send small
pose/depth metadata on an ordered/reliable channel with frame IDs; tolerate
dropped video frames and never pair metadata to a “nearest” decoded frame by
timestamp alone.

Bandwidth is an engineering measurement, not a constant: compressed RGB rate
depends on codec, resolution, frame rate, scene motion, and network adaptation.
Uncompressed depth alone scales with `width × height × bytes-per-sample ×
frames-per-second`, so continuous raw-depth upload is usually a poor default.
Adapt by sending:

* low-latency RGB continuously or only candidate frames;
* full-resolution RGB, high-confidence depth, descriptors, and mesh deltas on
  selected keyframes / when visual ambiguity is detected;
* a local-server result cache keyed by map version and frame ID; and
* no map-update upload during uncertain localization without explicit user
  consent or a vetted refresh workflow.

Home video and meshes are sensitive data. Use authenticated encrypted transport
and encrypted server-side map storage; define per-map authorization, retention
and deletion, access audit logs, key rotation, and whether human operators can
ever view frames. Make the connected mode opt-in, explain what leaves the
device, and preserve a usable local ARKit path if connectivity, authentication,
or server health fails. A server's failure state must visibly be
`server-unavailable; local tracking/fallback active`, never a frozen pose
presented as live.

### NeRF and Gaussian-splat relocalization: useful but not the first path

NeRF and 3D Gaussian Splatting are credible server-side map representations,
but their strongest established role is reconstruction/view synthesis rather
than arbitrary-start product relocalization. The original
[3D Gaussian Splatting paper](https://doi.org/10.1145/3592433) starts from
sparse calibrated points and optimizes/renders an explicit Gaussian scene;
the map still depends on accurate camera calibration. For localization,
[iNeRF](https://arxiv.org/abs/2012.05877) optimizes pose by minimizing the
difference between a NeRF rendering and an observation **from an initial pose
estimate**. That makes it a refinement/verification technique, not a global
place-recognition replacement.

Recent work is promising but not yet sufficient reason to replace
retrieval+PnP. [3DGS-ReLoc](https://arxiv.org/abs/2403.11367), for example,
still uses feature-based matching and PnP for its initial pose; recent work
also highlights pose-prior and geometric uncertainty in 3DGS refinement
([CVPR 2026](https://arxiv.org/abs/2603.16538)). A responsible server
experiment is therefore:

1. build an independently validated sparse RGB-D/SfM map first;
2. train a NeRF/3DGS from its calibrated poses (Nerfstudio is a maintained
   Apache-2.0 research framework with Gaussian-splat support
   [repository](https://github.com/nerfstudio-project/nerfstudio));
3. seed from the accepted retrieval+PnP pose only;
4. compare renderer-based refinement with ICP/reprojection refinement on
   identical held-out visits; and
5. reject on photometric/geometry disagreement or change-induced appearance
   mismatch.

Do not train a neural field from an unverified live stream and then use its
rendering likeness as localization proof. It can bake transient lighting,
people, and furniture into the appearance model.

## Accuracy, recall, and evaluation discipline

There is no defensible house-wide centimetre or “works from every room” number
without a device-specific ground-truth experiment. ARKit's own accuracy and
world-map relocalization policy are not specified as such a guarantee, and
published learned-method results use other sensors/datasets/hardware.

Evaluate three separate quantities:

| Property | Measurement | Pass/fail interpretation |
| --- | --- | --- |
| ARWorldMap baseline | Saved-map reopen from every room, several lighting and furniture conditions | Time-to-normal, success/indefinite-relocalizing rate, and relative repeatability; no assumed success rate. |
| Custom initial pose | Ground-truth-marked poses or a carefully surveyed reference rig used **only for development evaluation**, never operation | Translation/rotation error, recall at predeclared tolerances, false localization and abstention. |
| Ongoing track/recovery | Walk loops, occlusion/blur, pause/resume, changing rooms | Drift relative to repeatable reference, tracking-loss detection latency, and recovery correctness. |

For candidate model selection, run the same captured, permission-compliant
house dataset through: (a) Vision-print + ORB, (b) Vision-print + learned local
features, and (c) any learned-VPR retrieval option. Measure map bytes, cold and
warm latency, peak memory, energy/thermal state, recall, false accepts, and
relocalization time on the target iPhone. Only advance a model if it improves
the agreed safety/accuracy metric under a resource budget.

## iOS deployment and licence constraints

* **Vision Feature Print:** native/offline and therefore the lowest-integration
  retrieval choice. Persist request revision and regenerate an index after OS
  migration if validation says distances are not comparable.
* **Core ML:** Apple documents lower-precision neural weights as a way to
  reduce storage, including FP16 and lower-bit representations
  ([Apple](https://developer.apple.com/documentation/coreml/reducing-the-size-of-your-core-ml-app)).
  This supports an experiment with a quantized model; it does not prove that a
  particular PyTorch transformer converts correctly or meets latency. Validate
  numerical matching and device thermal behaviour after conversion. Keep fixed
  input sizes/keypoint caps and execute only candidate pairs off the render
  queue.
* **OpenCV:** `solvePnPRansac` is a practical iOS C++ bridge; OpenCV 4.5+
  releases are Apache-2.0 according to the project's
  [licence change record](https://github.com/opencv/opencv/wiki/ChangeLog/b7532bb957d4428df0f49b77ff086e7f592aa44e).
  Build a minimal `calib3d`/needed feature subset, not a blanket desktop
  dependency. Re-audit transitive notices in the exact release shipped.
* **HLoc:** Apache-2.0 at repository level
  ([repository](https://github.com/cvg/Hierarchical-Localization)); useful as a
  desktop evaluation oracle, not a runtime component. Its submodules and model
  weights require their own licence review.
* **LightGlue / SuperPoint:** LightGlue code and weights are Apache-2.0, but its
  own repository says original SuperPoint weights/inference have a restrictive
  licence; ALIKED is BSD-3-Clause
  ([licence section](https://github.com/cvg/LightGlue#license)). Glue Factory
  identifies an Apache-2.0 open SuperPoint variant and separately isolates
  non-free third-party models
  ([repository](https://github.com/cvg/glue-factory)). Select an explicitly
  redistributable extractor/weights pair before shipping; do not assume a paper
  or a GitHub star count grants commercial distribution rights.

## Implementation sequence

1. **Protect the baseline:** retain the existing ARWorldMap persistence,
   relocalization timeout, and map-frame tests. Instrument success, limited
   duration, and recovered tracking without changing the present offline
   behaviour.
2. **Define the observation protocol before video:** implement a versioned
   `frameID` envelope with ARFrame capture timestamp, AR-session ID, image
   geometry/orientation/intrinsics, `T_W_C`, tracking state, and optional
   depth/mesh metadata. Add fixtures for timestamp/frame-ID association,
   out-of-order delivery, session reset, and transform direction. Do not start
   a server pipeline until this contract has deterministic tests.
3. **Build the versioned map index:** opt-in local reference thumbnails, Vision
   feature-print index, ARKit intrinsics, high-confidence depth-backed
   landmarks, and local surfels. Archive the same data locally and upload it to
   a protected server map builder when connected mode is enabled. Add package
   migration and access-control/retention tests.
4. **Establish the server baseline:** build the map with COLMAP/HLoc-style
   sparse reconstruction and retrieval/matching/PnP, align it metrically to
   `M`, and publish it only with a replayed quality report. Return developer
   diagnostics and `unlocalized` results first; record a ground-truth revisit
   corpus before allowing an automatic map-pose handoff.
5. **Add the VIO-aware handoff:** accept only server PnP poses whose frame IDs,
   verification gates, and short-sequence checks pass; compute `T_M_W` at the
   capture instant and let the client track thereafter. Add end-to-end delayed
   response, reconnect, and ARSession-reset tests.
6. **Add contract-C geometry:** request selected high-confidence depth/mesh,
   run local robust point-to-plane refinement near the PnP proposal, and
   enforce residual/overlap/degeneracy rejection. Benchmark it against RGB+B
   on the same home corpus; only then make depth upload adaptive by ambiguity.
7. **Keep the local verified fallback:** add the compact ORB/PnP path first;
   benchmark a legally usable exported extractor + LightGlue pair against it on
   the same iPhone/home corpus, including memory/thermal measurements. Promote
   it only when it improves false-accept/relocalization results inside budget.
8. **Harden long-term behaviour:** landmark staticness, semantic/dynamic masks
   if justified by data, change-aware confidence, map refresh/versioning,
   server privacy controls, and recovery tests. Keep the UI explicit about
   `relocalizing`, `server-verifying`, `visual-only`, `geometry-verified`,
   `tracking`, `unlocalized`, and `server-unavailable/local-fallback` states.

## Bottom line

ARKit can solve much of the desired pipeline and should remain in charge of
normal tracking. Its saved map is not an API guarantee of arbitrary-room global
relocalization. When connected, a server can run the most capable practical
map-building and matching stack, but must return a frame-specific, geometrically
verified pose that the client safely bridges into ARKit. When disconnected, a
compact depth-backed hierarchical fallback preserves the same safety model:
retrieval proposes a place, PnP establishes a metric pose, LiDAR checks it, and
ARKit takes over at high-rate in a stable house frame. This staged design keeps
the working app useful at every phase while reserving neural-field and heavier
learned models for evidence-based evaluation rather than optimistic
architecture.
