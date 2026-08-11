# AR runtime performance audit

**Scope:** static audit of ARSessionController, ARSceneView, MapOverviewView, and
ExperienceScreen at commit b119d2d. This report identifies source-visible work; it
does **not** report, infer, or extrapolate iPhone performance.

## Method and limitations

Source was inspected on 2026-08-11. Reproducible static measurements:

| Check | Method/source | Raw result |
| --- | --- | --- |
| Observable controller state | `rg -n '@Published' HouseMapper/AR/ARSessionController.swift \\| wc -l` | 16 properties |
| Frame callback queue | ARSessionController.swift:56-60 | AR session delegate queue is .main |
| Coverage update cadence | frameCount.isMultiple(of: 8) at :379 | 1/8 frames (7.5/s if 60 fps; arithmetic only) |
| Coverage cap | :380,391-394 | 2,000 displayed cells |
| Trail cap | :373-375 | 1,000 points / 999 segments |
| Canvas input bound | MapOverviewView.swift:11 | 3,001 points when both caps are full |
| Canvas primitive bound | MapOverviewView.swift:39-51 | 2,000 fills + one 999-segment path/redraw |
| Confidence sampling | ARSessionController.swift:419-424 | one byte per 4x4 source pixels |
| Local compile attempt | `xcodebuild -list -project HouseMapper.xcodeproj` | unavailable: active developer dir is CommandLineTools, not Xcode |

No iPhone 16 Pro, Xcode, Instruments, MetricKit payload, AR recording, or trace was
available. Actual CPU/GPU time, FPS, memory, energy, thermal state, depth resolution,
mesh-anchor/triangle count, and callback frequency remain unknown. The README also
correctly notes that Simulator cannot validate LiDAR, ARWorldMap tracking, or
relocalization performance.

## Ranked findings

### 1. Per-frame main-thread publishing drives the whole SwiftUI overlay — must do

The controller is @MainActor (ARSessionController.swift:7) and configures the AR
session delegate queue as .main (:58-60). Every didUpdate calls consume(frame:)
(:448-451). It updates tracking/mapping text and progress, feature count, depth
status, creates a pose, and updates mapping or relocalization state (:259-323).
Mapping publishes pose every frame (:279-285); gated relocalization publishes it
after success (:317-322). Several helpers assign @Published values without first
checking whether the derived value changed (:294-364).

ExperienceScreen owns the controller as a @StateObject (ExperienceScreen.swift:7,
20-23) and passes its live pose/arrays to MapOverviewView (:49-54), so those
publications can invalidate the complete overlay and Canvas on the same main queue
that receives AR frames. The source has 16 published properties; that is a static
state count, not a count of renders or notifications.

**Change:** retain a non-published latest AR pose for localization correctness, but
publish an immutable display snapshot at a measured fixed cadence (initially compare
10, 15, and 30 Hz). Equality-guard stable strings/progress/confidence/can-save
values; update elapsed time on a one-second timer rather than each frame. Coalesce
instead of queuing one MainActor task per incoming frame.

**Expected mechanism:** fewer objectWillChange sends, body/Canvas rebuilds, and less
competition with ARKit delivery on the main thread.

**Risk:** UI throttling must never alter the state machine or permit a pose before
the saved origin/map match is established. Unit-test gating separately from display
cadence.

### 2. Mesh geometry/material recreation happens for every mesh-anchor update — must do

Both didAdd and didUpdate assign a newly built SCNGeometry
(ARSessionController.swift:486-503). One update creates two SCNGeometrySources, one
SCNGeometryElement, one SCNGeometry, one SCNMaterial, and a translucent UIColor
(:505-535). There is no material cache, throttle, or visualization switch. Scene
reconstruction is enabled whenever supported (:216-227), and the view also enables
automatic lighting, 4x MSAA, feature points, and world-origin debug overlays
(:61-64).

Even if ARKit buffers are Metal-backed, rebuilding SceneKit wrappers/materials per
anchor update is likely allocation, render reconciliation, blending, and GPU work.
Severity depends on observed anchor rates and mesh complexity, so profile it rather
than asserting a millisecond cost.

**Change:** make mesh visualization/debug overlays opt-in; use a cached shared
material; and compare a baseline configuration without scene reconstruction to one
with reconstruction but no rendering. Retain reconstruction only where a user-visible
or recorded feature requires it.

**Expected mechanism:** removes repeated SceneKit object creation and optional visual
GPU load from the normal AR loop.

**Risk:** preserve a diagnostic switch and verify ARWorldMap persistence and anchor
handling with visualization off. Rendering off and reconstruction off are separate
experiments.

### 3. The overview Canvas copies data and issues many small draw operations — must do

Every Canvas redraw concatenates map points, trail, and current pose
(MapOverviewView.swift:9-12), then allocates two coordinate arrays for min/max
bounds (:22-29). It creates/fills a path for each map point (:39-43) and builds a
trail path one segment at a time (:45-52). At existing caps it processes up to 3,001
inputs, creates at least the concatenated input plus two coordinate arrays, does up
to 2,000 fill calls, and adds up to 999 trail segments per redraw. Finding 1 can
request this work at AR-frame cadence.

**Change:** separately cap rendered data (for example 500 map cells / 250 simplified
trail points), calculate bounds in one loop without concatenation, batch dots into
one Path/fill, and cache projection/bounds per published snapshot.

**Expected mechanism:** bounded linear work and far fewer Canvas calls/temporary arrays.

**Risk:** keep full diagnostic data if needed, always include current localized pose,
and verify simplification does not hide relevant coverage gaps.

### 4. Coverage rebuilding is periodic full-set conversion — should do

Every eighth frame before saturation, feature samples are inserted into a Set, then
the full grid is converted to a new SIMD2 array and published
(ARSessionController.swift:378-394). The custom Array.stride(from:by:) first
materializes a sampled array (:549-553). At hypothetical 60 fps, this may run 7.5
times/s until the 2,000-cell cap; that is static arithmetic, not a device result.
Set enumeration order is non-deterministic.

**Change:** sample by integer index directly, retain an append-only render cache for
newly discovered cells, and publish only after a meaningful addition or at the UI
cadence. Preserve the existing 0.20 m quantization/deduplication.

**Risk:** a cache must never exceed the cap or diverge from coverageGrid.

### 5. Full ARKit feature set and depth scan need a device decision — device-dependent

The configuration enables horizontal/vertical planes, environment texturing, scene
reconstruction, scene depth, and smoothed depth whenever available
(ARSessionController.swift:209-240). The once-per-second confidence inspection locks
a pixel buffer and samples every fourth row/column (:396-431). It runs on the main
actor. Its pixel count, lock duration, and interaction with ARKit workloads cannot
be known from source.

**Change:** compare a capability matrix: (A) ARWorldMap baseline, (B) plus depth
diagnostics, (C) plus reconstruction without rendering, and (D) full mesh/debug
visualization. Scan depth only while its diagnostic is visible.

**Risk:** configuration changes can change mapping/relocalization outcomes, so use
the same saved maps and routes for every variant.

### 6. Trail eviction causes bounded main-thread copying — should do

After the 8 cm movement test, the trail appends and calls removeFirst when it exceeds
1,000 points (ARSessionController.swift:366-375). That shifts retained elements, an
avoidable O(n) compaction during long walks.

**Change:** use a ring buffer or amortized compaction, then publish an ordered
display snapshot at the chosen UI cadence.

**Risk:** preserve chronological ordering and the 8 cm threshold.

## Object lifetime and memory/thermal notes

ARSceneView.dismantleUIView pauses the session and clears delegates
(ARSceneView.swift:15-19); the controller holds the view weakly
(ARSessionController.swift:31). There is no obvious controller/view retain cycle in
the inspected paths. The loaded world map is intentionally retained for retry
(ARSessionController.swift:42,115-117), but its size must be measured. Continuous
mesh geometry assigned to anchor nodes is a more plausible sustained memory/thermal
source. snapshot().jpegData is a save-time spike (:174), not a continuous hot path.

## Implementation priorities

### Must do before broad physical testing

1. Add opt-in signposts/aggregate timers around frame consume, mesh creation, depth
   scan, coverage snapshot, and overview render. Record no camera frames or location.
2. Decouple/coalesce display state with equality guards while preserving AR-frame
   localization gating.
3. Make mesh/debug rendering opt-in and cache its material.
4. Batch/bound overview work and remove hot-path full coverage conversions.

### Device-dependent items

1. Production defaults for reconstruction, either depth semantic, plane detection,
   environment texturing, MSAA, and debug overlays.
2. Presentation cadence and render-point/trail budgets.
3. Battery, thermal, FPS, accuracy, and relocalization-recall claims.

## iPhone 16 Pro validation protocol

1. Build a release-like instrumented app. Record iOS/app build, lighting, route,
   map feature count, and package size for medium and whole-house maps.
2. Run four five-minute mapping and four five-minute relocalization walks per map:
   baseline, +depth, +reconstruction-not-rendered, and full mesh/debug. Randomize
   order or cool down between variants.
3. Capture Time Profiler, Allocations, Core Animation/Metal frame data where
   available, and Energy Log. Attribute work with signposts named frameConsume,
   meshGeometry, depthScan, coverageSnapshot, and overviewRender.
4. Record median/p95/max main-thread frame work, displayed frame rate/drops,
   CPU/GPU/energy summary, peak/sustained resident memory, mesh anchor/triangle
   counts, and thermal transitions.
5. Restart and relocalize from at least three known starts. Record success rate,
   time to gated pose, tracking recovery, and reference-point pose error.
6. Accept a change only when paired repeat runs reduce its target cost without
   weakening localization gating, success/time, or diagnostic readability.

## Regression-test boundary

Pure tests should cover display coalescing/equality suppression, coverage
deduplication/caps, deterministic downsampling, trail chronology, and the rule that
a withheld relocalization pose remains withheld regardless of UI cadence. ARKit
timing, depth buffers, rendering/GPU work, thermal state, and world-map performance
are device/instrumentation tests, not deterministic unit tests.
