# Feature and spatial-map correction plan

Date: 2026-08-11

This plan follows the diagnosis in `06-feature-map-diagnosis.md`. Each slice begins
with a failing behavioral test, implements one public seam, and records a benchmark
before moving to the next slice.

## Product direction

**Visual thesis:** a camera-first spatial instrument on a quiet black surface;
cyan means measured live structure, orange means unresolved alignment, and green is
reserved for verified saved-map support.

**Content plan:** live camera and real projected landmarks are the primary workspace;
the saved 3D map and route are secondary context; pose/confidence are compact
instruments; one bottom action controls save or retry.

**Interaction thesis:** landmark updates settle rather than flash, localization uses
a restrained search sweep driven by real state, and the green lock transition occurs
only after the relocalization gate succeeds. Motion never fabricates measurements.

## Confirmed behavioral seams

The requested pipeline defines the public test seams:

1. projected real observations → bounded, distributed on-screen landmark snapshot;
2. spatial snapshot → package save/load → structurally identical snapshot;
3. saved 3D snapshot → deterministic map render model;
4. loaded map plus relocalization evidence → honest point roles and published pose.

Tests will assert behavior through these seams rather than private controller calls.

## Slice 1 — observable, visible-first feature presentation

1. Introduce a pure feature-selection input containing landmark ID and normalized
   visible position.
2. Add tests proving that invisible candidates do not consume the display budget,
   saved priorities survive selection, selection is deterministic, and coverage is
   spatially distributed.
3. Project all ARKit raw landmarks at the 10 Hz display cadence, recording precise
   rejection counters, then select only from visible candidates.
4. Publish source, visible, displayed, restored-ID, camera-resolution, effective-FPS,
   and tracking diagnostics in one immutable display snapshot.
5. Keep Canvas drawing batched. Choose the initial visible cap from benchmark data,
   not by increasing dot size.

Benchmark gates:

- deterministic selection over 1k, 5k, 20k, and 100k synthetic visible candidates;
- allocation and elapsed-time comparison against the current sampling function;
- on-device signposts for projection and publication p50/p95, displayed FPS, thermal
  state, source/visible/display ratios, and ARKit tracking state.

## Slice 2 — lossless app-owned spatial snapshot

1. Define schema v2 `SpatialMapSnapshot` records for map-frame landmarks, stable
   identifiers, bounds, and mesh anchors (anchor transform, vertices, normals,
   triangle indices, and classifications where available).
2. Build the snapshot from the exact `ARWorldMap` being archived, not from the lossy
   live overview grid.
3. Encode the snapshot as a compact binary property list in the staged package and
   add a checksum/integrity manifest.
4. Load snapshot and ARWorldMap together. Derive an in-memory fallback snapshot for
   schema-v1 packages so existing user maps remain usable.
5. Validate identifier/count/bounds consistency and reject corrupt packages with an
   actionable error instead of silently drawing a different map.

Benchmark gates:

- round-trip equality for fixed known 3D fixtures;
- 10k/100k landmark encode/decode time and byte size;
- malformed, truncated, mismatched-ID, and legacy-package tests;
- full package save/load timing outside the main actor.

## Slice 3 — faithful map visualization

1. Replace the mapping coverage-grid input with the current full spatial snapshot or
   a clearly labelled coverage layer; do not call the grid the saved map.
2. Add a deterministic render model that retains 3D coordinates and uses view-level
   LOD only at render time. Always retain route, current camera, bounds, and verified
   support landmarks.
3. Build a dark SceneKit/Metal point-and-mesh map panel matching the reference's
   structure: neutral map landmarks, cyan current observations, green verified
   support, and a thin contrasting trajectory.
4. Preserve user-selected orbit/top-down view without mutating map coordinates.

Benchmark gates:

- render-model construction for 10k/100k landmarks and representative mesh sizes;
- screenshot/layout tests for empty, mapping, seeking, localized, and tracking-loss
  states;
- iPhone GPU frame time, memory, and thermal measurements with map panel hidden and
  visible.

## Slice 4 — correct relocalization evidence

1. Change seeking-state points to neutral; restored-ID points may become green only
   after the origin-plus-normal-tracking gate succeeds.
2. Keep nonmatching live support cyan/neutral after localization.
3. Rename UI metrics to distinguish `live`, `visible`, `displayed`, and `restored map
   IDs`; never call them geometric inliers.
4. Add recovery tests proving green and map pose are withdrawn on tracking loss.

For actual reference-equivalent green correspondences, add the connected backend as
a subsequent milestone: frame envelope → retrieval → LightGlue/local matching →
PnP/RANSAC → optional depth verification → accepted inlier coordinates returned to
the phone. That server result gets a separate evidence type and confidence gate.

## Slice 5 — explicit import/export

1. Export the versioned app package as one document while keeping map data private by
   default.
2. Import only documented package versions with checksum, coordinate-frame, units,
   and identifier validation.
3. Add format-specific importers (PLY/OBJ/COLMAP) only after receiving an actual
   source artifact and declaring its axes, scale, camera model, and landmark schema.
4. Never infer a 3D map from the supplied raster reference screenshot.

## Verification and delivery

For each major slice:

1. demonstrate the test failing before implementation and passing afterward;
2. run `xcodebuild` for generic iOS plus the test target where supported;
3. run deterministic host benchmarks and record raw results under `docs/benchmarks`;
4. run the documented iPhone 16 Pro route protocol and record device, OS, lighting,
   map size, tracking states, thermals, and relocalization outcome;
5. inspect the produced package to prove the saved and loaded snapshot agree;
6. commit and push only after the slice's correctness and benchmark gates pass.

