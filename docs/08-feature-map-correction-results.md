# Feature and saved-map correction results

Date: 2026-08-11

This records the first implemented correctness slice from
`07-feature-map-implementation-plan.md`. It does not claim reference-equivalent
SfM localization or completed physical-device performance validation.

## Implemented

### Real visible-feature presentation

- HouseMapper still uses ARKit's real `ARFrame.rawFeaturePoints`; no decorative or
  independently detected display-only points were added.
- Every raw candidate is projected and visibility-tested before the 240-point draw
  budget is applied. Behind-camera, invalid-projection, and outside-viewport losses
  are counted separately.
- Visible selection is deterministic, spatially distributed, and preserves restored
  map IDs as priorities only after ARKit has passed the localization gate.
- The header now distinguishes displayed, visible, and source counts and reports the
  measured AR camera resolution and effective delivered frame rate.

### Honest localization colors

- Mapping observations are cyan.
- Relocalization candidates remain neutral while ARKit is seeking the map.
- After origin restoration plus normal tracking, current saved-ID overlaps are
  green and other current support remains cyan.
- The UI labels these as restored IDs, not descriptor matches or PnP inliers. ARKit
  does not expose its internal correspondence/inlier set.

### Faithful saved landmark representation

- Every exposed landmark ID and full `(x,y,z)` position from the exact saved
  `ARWorldMap` is encoded into `spatial-map.plist` beside the opaque world-map
  archive.
- Decode validates schema, map ID, unique IDs, finite positions, exact bounds, and
  metadata/payload landmark count.
- Existing packages without the sidecar derive the same representation from their
  stored `ARWorldMap`, preserving backwards compatibility.
- During mapping, a bounded 50,000-ID accumulator retains real ARKit landmarks after
  they leave the camera. Once Save completes, the exact saved snapshot replaces the
  live accumulator as the displayed authority.
- The overview retains full-cloud 3D bounds and draws a deterministic 4,000-point
  spatial LOD. Height is represented by four batched intensity bands rather than
  being discarded. The UI reports source and rendered counts.

## Verification evidence

- Debug generic-iOS `build-for-testing`: succeeded.
- Release generic-iOS build: succeeded.
- Project plist validation and `git diff --check`: passed.
- New behavior tests cover capture cadence, visible-first selection, priority and
  quadrant retention, honest point roles, live landmark retention/eviction, exact
  snapshot round-trip, corrupt count rejection, and render-model bounds/coverage.
- The XCTest target compiles. Execution on this host could not start because the
  repository has no persisted Apple Development team/certificate and an iOS test
  host cannot be installed with ad-hoc signing. Run Product → Test in the signed
  Xcode project to execute it on the developer machine/device.

Benchmark reports and raw methodology:

- `benchmarks/05-feature-selection.md`
- `benchmarks/06-spatial-map-snapshot.md`
- `benchmarks/07-map-render-model.md`

All reported numbers are arm64 Mac microbenchmarks. They are not presented as
iPhone 16 Pro frame-time, thermal, energy, or camera-performance results.

## Physical iPhone validation protocol

1. Install the new build, create a new map, and record the displayed resolution,
   effective FPS, source/visible/display counts, tracking state, and LiDAR status.
2. Scan the same textured route three times at slow, moderate, and deliberately fast
   motion. Compare raw-count loss with ARKit's excessive-motion and
   insufficient-feature states.
3. Save, note the final landmark count, close the app, reopen the package, and verify
   the saved-map panel reports the identical source count.
4. Start relocalization in the mapped room. Confirm candidates are neutral while
   seeking, pose is withheld, and green restored IDs appear only after localization.
5. Cover the camera or move rapidly to force tracking loss. Confirm the map pose and
   green evidence are withdrawn, then recover in a distinctive mapped view.
6. Use Instruments signposts/GPU capture in a later device-performance slice before
   increasing the 240 overlay or 4,000 map-render caps.

## Still required for the stated end goal

- Persist and faithfully render app-owned mesh vertices/faces/classification rather
  than relying only on the opaque ARWorldMap and live SceneKit anchors.
- Add a checksummed/chunked map container and explicit document import/export.
- Receive an actual external spatial artifact before implementing a format-specific
  importer; the supplied raster reference cannot recreate its source 3D map.
- The connected visual retrieval → learned local matching → PnP/RANSAC backend is
  implemented in `server/`. Schema-v2 synchronized depth verification and held-out
  arbitrary-start accuracy trials remain required.
- Run repeated iPhone 16 Pro accuracy, latency, memory, energy, and thermal trials.
