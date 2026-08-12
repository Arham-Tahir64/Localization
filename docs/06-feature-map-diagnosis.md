# Feature and saved-map diagnosis

Date: 2026-08-11

## Scope and evidence

This diagnosis traces the shipping code from `ARFrame` through the camera overlay,
and from `ARWorldMap` through persistence, reload, visualization, and
relocalization. It also compares that behavior with the supplied Over devs Reality
reference. No production code was changed while preparing this document.

No external point-cloud, mesh, keyframe database, or map archive was found in the
repository or supplied attachments. The supplied artifact is a raster reference
image. Therefore there is currently no external “uploaded map” for the app to parse.
The only import-like operation implemented by the app is loading a package that the
same app previously saved.

## Feature pipeline: what actually exists

### Detector and tracker

The app does not run FAST, Harris, ORB, SuperPoint, SIFT, Vision keypoint detection,
or an image preprocessing pipeline. It reads `ARFrame.rawFeaturePoints`, an
ARKit-owned sparse 3D point cloud used/exposed by world tracking. Apple controls the
detector, descriptor, track management, thresholds, and landmark retirement; those
parameters are not public ARKit tuning knobs.

The app does not use `capturedImage` for feature extraction and does not maintain a
separate temporal feature track. Scene depth is sampled for a once-per-second status
label only. LiDAR mesh geometry is rendered by SceneKit, but it is not converted into
additional visual landmarks.

### App-level configuration

`ARWorldTrackingConfiguration` currently enables:

- gravity alignment;
- horizontal and vertical plane detection;
- automatic environment texturing;
- the default ARKit video format;
- classified scene reconstruction when available, otherwise mesh reconstruction;
- both `sceneDepth` and `smoothedSceneDepth` when supported.

No camera resolution or frame rate is selected explicitly. There is no app-level
exposure control or image preprocessing. The effective camera resolution, frame
cadence, ambient illumination, tracking state, and per-stage rejection counts are
not recorded, so the current UI cannot distinguish poor capture conditions from
presentation loss.

### Presentation thresholds and losses

The important thresholds are not detector thresholds; they are display filters:

| Stage | Current behavior | Consequence |
| --- | --- | --- |
| Feature count label | Reads the raw point count every 0.25 s | This count is not the number drawn |
| Overlay publication | At most every 0.10 s | UI is intentionally 10 Hz |
| Overlay source sampling | Samples at most 240 points from the full world point cloud | Hard display cap |
| Saved-ID priority | Reserves at most 120 priority indices | Other candidates are evenly sampled |
| Frustum filtering | Happens **after** the 240-point sample | Off-screen/behind-camera samples consume the budget and are then discarded |
| Behind-camera rejection | Rejects camera-space `z >= -0.05 m` | Correct geometric cull, but late |
| Viewport rejection | Rejects nonfinite/out-of-bounds projections | Correct cull, but late |
| Mapping overview input | Every eighth frame, samples about 120 raw points | Does not represent every mapped landmark |
| Mapping overview quantization | X/Z rounded to a 0.20 m grid | Deliberately destroys local structure |
| Mapping overview cap | 1,000 occupied cells | Deliberately bounded sketch |
| Reloaded overview | Stride-samples at most 1,000 saved points and drops Y | Lossy top-down representation |

The visible overlay can therefore contain far fewer than 240 points even when ARKit
reported hundreds or thousands: selection occurs before visibility is known. This is
the clearest app-controlled cause of unexpectedly sparse on-camera feedback.

### Tracking-quality effects

ARKit can reduce or lose landmarks under excessive motion, blur, low texture, poor
lighting, repeated texture, close blank walls, and initialization/relocalization.
The app reports ARKit's high-level tracking reason but records no effective FPS,
frame resolution, source/visible/displayed counts, or rejection ratios. It therefore
cannot yet prove which capture condition dominates a specific walk.

### Comparison with the reference

The reference states that its mall map used 17,959 registered fisheye camera poses
over roughly 50,000 square metres, then relocalized an ordinary phone video against
that map. The large view shows a global sparse reconstruction containing many
thousands of landmarks; green points are presented as query-to-map localization
support.

That is not equivalent to an `ARFrame.rawFeaturePoints` overlay. ARKit's live sparse
VIO landmarks are appropriate for a real-time `ARWorldMap` proof of concept, but they
cannot reasonably match the density, global scale, descriptors, keyframes, or
explicit 2D-to-3D correspondence display of a server/offline SfM localization
system. Increasing dot size would not close this technical gap.

## Saved-map pipeline: what actually exists

### Save

1. `ARSession.getCurrentWorldMap` returns an `ARWorldMap`.
2. The app ensures an identity map-origin anchor exists.
3. `NSKeyedArchiver` writes the complete opaque ARKit map to
   `worldmap.arexperience` using secure coding.
4. `metadata.json` stores center, extent, raw feature count, and capability flags.
5. One camera screenshot is stored as `preview.jpg`.

There is no app-owned landmark table, keyframe collection, visual descriptor store,
depth point cloud, or mesh sidecar.

### Discovery and load

`MapLibrary.refresh` accepts only app packages containing metadata and an AR world
map. `loadWorldMap` secure-unarchives the same `ARWorldMap`. This archive path is not
currently simplifying the world map before ARKit receives it; it is the strongest
part of the pipeline.

There is no document picker, uploaded-map parser, PLY/OBJ/PCD/COLMAP reader, or
external-map schema. A raster screenshot cannot be converted back into the original
3D reconstruction.

### Rendering

The visual discrepancy is introduced mainly after capture, not by the keyed archive:

- During mapping, the “LIVE MAP” is a 20 cm X/Z coverage grid accumulated from
  periodic live samples, not the current saved `ARWorldMap`.
- During relocalization, the app reads saved raw feature points but stride-samples
  them to 1,000 and projects only X/Z.
- Y/height, landmark identity, density, mesh faces, classification, and any
  keyframe/image relationship are absent from the overview.
- The mini overview is therefore a bounded occupancy sketch, not a faithful display
  of the saved spatial map.

### Relocalization and green-point semantics

Relocalization itself passes `initialWorldMap` back to ARKit, resets tracking, waits
for ARKit to restore the named origin anchor, and withholds pose until tracking is
normal. The coordinate contract is consistent for this backend: after successful
ARWorldMap relocalization, map and restored AR world frames coincide.

The overlay does not have access to ARKit's actual descriptor matches or PnP
inliers. It currently compares saved and live `ARPointCloud` identifiers. Worse, the
presentation turns every live `.localizedSupport` point green after the session is
localized, even if its identifier was not in the saved set. That makes the visual
claim stronger than the available evidence.

## Root-cause classification

| Area | Finding |
| --- | --- |
| Detection | ARKit-owned sparse VIO landmarks; no custom detector or configurable threshold |
| Filtering | Definite defect: sampling precedes visibility filtering; hard 240-point display cap |
| Capture | Default ARKit format; no evidence yet that resolution/FPS/exposure is the cause |
| Tracking | Can reduce raw landmarks, but current telemetry cannot quantify the contribution |
| Serialization | ARWorldMap is archived and loaded intact; no proven loss here |
| Loading/import | App-saved ARWorldMap only; external uploaded-map ingestion does not exist |
| Representation | No app-owned full landmark/mesh snapshot or descriptors/keyframes |
| Coordinates | ARWorldMap relocalization frame contract is coherent; overview intentionally drops Y |
| Rendering | Definite major loss: 20 cm grid or 1,000-point X/Z sample instead of stored 3D structure |
| Match display | Definite semantic overclaim: green does not mean verified 2D-to-3D inlier |

## Necessary changes

1. Add capture and projection diagnostics: source, visible, displayed, behind-camera,
   out-of-bounds counts; effective frame cadence; image resolution; tracking and
   mapping states. This is required to diagnose real iPhone walks.
2. Project/filter first, then deterministically select spatially distributed visible
   ARKit landmarks. This fixes a real loss without inventing points.
3. Save an app-owned, versioned spatial snapshot alongside `ARWorldMap`, preserving
   every exposed landmark's 3D position and identifier plus mesh structure when
   present. Existing ARWorldMap remains authoritative for ARKit relocalization.
4. Load and render that snapshot directly. Rendering may use deterministic level of
   detail, but it must not confuse a coverage grid with the stored map.
5. Make green mean verified state only: no green before gated relocalization, and no
   green for current points lacking saved-map identity evidence. Label the evidence
   honestly as restored landmark identity, not descriptor/PnP matches.
6. Add package integrity checks that compare metadata, snapshot counts/bounds, and
   loaded ARWorldMap counts before a map is offered for relocalization.

## Optional or later changes

- Selecting a non-default ARKit video format is device-dependent and must be accepted
  only after repeat iPhone benchmarks show better landmark retention without harming
  tracking, thermals, or relocalization.
- A custom image feature detector is useful only if its keypoints/descriptors are
  saved and used by a geometric relocalizer. A display-only detector is rejected as
  visual fakery.
- Matching the reference's actual density and correspondence semantics requires the
  connected HLoc/COLMAP-style backend described in
  `docs/research/04-sota-localization-2026.md`: retrieval, local descriptors,
  2D-to-3D matching, PnP/RANSAC, depth verification, and server-side map building.
- External PLY/OBJ/COLMAP/package import requires a declared source format and frame
  convention. The current raster reference image is not an importable spatial map.

