# Physical iPhone mapping and relocalization benchmark workflow

Date: 2026-08-11

## Why this exists

The camera overlay alone cannot distinguish these materially different causes of
low apparent feature density:

* ARKit supplied few `rawFeaturePoints`.
* Many supplied points were behind the camera or outside the current viewport.
* The real visible set exceeded HouseMapper's 240-point draw budget.
* Tracking spent meaningful time limited because of motion or insufficient
  texture.
* Camera delivery rate or depth confidence degraded under load.

HouseMapper now records those causes separately. No extra detector or decorative
point is introduced by this instrumentation.

## Recorded mapping/relocalization evidence

Each session report is schema-versioned JSON containing:

* physical hardware identifier, iOS version, app version, timestamps and duration;
* delivered AR frame count, camera resolution, effective capture FPS, and counts
  for every ARKit tracking-state category;
* sampled mean/max source, viewport-visible, and displayed feature counts;
* counts rejected behind-camera, invalid-projection, or outside-viewport;
* samples where visible real features exceeded the draw budget;
* restored saved-landmark identity counts after ARKit pose lock;
* depth dimensions and sampled high-confidence fraction;
* exact saved landmark, mesh-anchor, mesh-vertex, and triangle counts;
* spatial sidecar/package bytes and save or load I/O duration.

Mapping reports are stored at `benchmark.json` inside the validated map package.
Relocalization reports are embedded in Validation History records. The saved-map
ellipsis menu and Validation Detail toolbar expose Share actions, so reports can
be exported directly from the phone without Xcode.

## Repeatable iPhone protocol

1. Install the current build and create a **new** map. Existing schema-1 packages
   cannot retroactively contain mesh that an older build never captured.
2. Scan one fixed route at a slow walking pace, including textured architecture,
   blank walls, and one turn between rooms. Save only after ARKit reports mapped.
3. Share the map's Device Benchmark JSON from its ellipsis menu.
4. Force-quit HouseMapper, start in a mapped but non-preview room, open that saved
   map, and follow the same slow observation motion until localized or timed out.
5. Open Validation History, select the attempt, and share its benchmark JSON.
6. Repeat three times from distinctive locations and three times from visually
   ambiguous locations. Intentionally include one excessive-motion run and one
   dim-light run.
7. Compare false localization, timeout, time-to-lock, source/visible/displayed
   features, limited-state proportions, mesh scale, and depth confidence. Do not
   tune from the best run alone.

Ground-truth pose accuracy still requires measured reference locations/orientations
in the home. A successful ARKit tracking state is relocalization evidence, not a
centimetre-error measurement.
