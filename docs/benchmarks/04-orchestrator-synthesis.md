# Benchmark synthesis and optimization decisions

Date: 2026-08-11

This document consolidates the independent AR runtime, relocalization, and
persistence audits. The source changes below improve bounded work and correctness;
they do not establish physical iPhone performance or localization accuracy. Those
claims require the repeatable iPhone 16 Pro protocols in the three worker reports.

## Implemented in this optimization pass

| Area | Before | Implemented change | Expected mechanism |
| --- | --- | --- | --- |
| Pose UI publication | Camera pose could publish at AR-frame cadence | Display pose is capped at 15 Hz; mapping diagnostics at 4 Hz; the state machine still consumes every frame | Fewer SwiftUI and Canvas invalidations without weakening pose gating |
| Relocalization timer UI | Elapsed time could publish every frame | UI elapsed time changes once per whole second; a monotonic uptime clock and independent fallback task enforce the deadline after a 250 ms callback-order grace | Less observable-object churn, a timeout that does not depend on another AR frame, and no race with a valid observation at the 45-second boundary |
| Confidence | 15/60-frame thresholds changed meaning with camera FPS | Medium/high require 0.5/2.0 seconds of uninterrupted normal tracking with restored map origin | Stable policy across 30/60 FPS and frame drops |
| Invalid timing | Negative or non-finite elapsed values could avoid timeout | Invalid or decreasing monotonic time fails closed with a diagnostic reason | Prevents indefinite or contradictory localization state |
| Deadline boundary | A valid map match at exactly 45 seconds lost to timeout | A valid normal/origin-present observation wins the same-callback boundary | Avoids discarding a match delivered at the deadline |
| Coverage data | Rebuilt a displayed array from the full grid repeatedly, up to 2,000 points | Append-only render points, capped at 1,000 and published at most twice per second | Bounded copying and fewer Canvas refreshes |
| Overview drawing | Multiple temporary arrays and one fill per point | One-pass bounds, bounded trail sampling, and a single batched point path/fill | Fewer allocations and draw calls |
| Trail retention | `removeFirst()` after every point beyond the cap | Removes 50 points only after reaching 650, retaining roughly 600 | Amortizes array shifting while preserving recent path order |
| Mesh visualization | Recreated geometry and material for every mesh-anchor update | One shared material and geometry refresh capped at 5 Hz per anchor | Reduces SceneKit allocation/reconciliation pressure |
| Rendering quality | 4x multisample antialiasing was always enabled | Default reduced to 2x | Reduces baseline GPU work while retaining antialiasing |
| Package boundary | UUID-named symlink packages could be listed and loaded | Discovery rejects symlinks; load, rename, and delete share canonical path/UUID validation | Keeps external or forged packages outside the map library boundary |
| Package commit | Same-ID save removed the existing final package before moving staging | Unique staging names and collision refusal preserve the existing complete package | Removes the prior destructive replacement window |
| Package sizes | A cancelled refresh could publish stale detached work | A generation token permits only the newest refresh to publish sizes | Prevents stale size snapshots after rapid refreshes |

## Added automated coverage

- Relocalization tests cover anchor ordering, exact timeout behavior, invalid and
  decreasing timestamps, FPS-independent confidence, 10,000 fixed-seed state
  updates, 500 rigid-transform trials, and a 100,000-update performance metric.
- Persistence tests cover package filtering, symlink rejection across discovery and
  operations, refresh generations, malformed validation history, bounded retention,
  mapped archive reads, and synthetic refresh/retention metrics.
- Both files are members of the `HouseMapperTests` target so hosted CI compiles them.

## Deliberately deferred until device evidence

The AR session delegate remains on the main queue because moving ARKit/SceneKit
callbacks across actors is a higher-risk concurrency redesign. Scene reconstruction,
depth, debug feature points, and mesh rendering also remain enabled because they are
part of the current mapping visualization requirement. The device matrix in
`01-ar-runtime.md` should first quantify each option before introducing runtime
quality modes.

Metadata discovery and validation-history serialization remain main-actor work.
Their normal retained datasets are small, and moving them requires generation and
error-ordering semantics beyond the measured evidence currently available. Run the
synthetic XCTest metrics and Instruments protocol from `03-persistence.md` before
that refactor.

A post-localization recovery deadline remains a product policy decision. The system
continues attempting ARKit recovery after a successful initial localization and
withholds pose whenever tracking/origin validity is lost. Physical trials should
determine whether a separate warning or retry threshold improves safety.

## Required physical-device gate

Use a release-like build on an iPhone 16 Pro and execute all three linked protocols:

1. `01-ar-runtime.md`: Time Profiler, Allocations, rendering, energy, memory, and
   thermal comparisons across depth/reconstruction/visualization variants.
2. `02-relocalization.md`: randomized arbitrary-start trials, time to first gated
   pose, pose error, timeout rate, and tracking-loss recovery.
3. `03-persistence.md`: cold/warm library refresh, archive load/save memory and time,
   fault-injected save recovery, and validation-history scaling.

Accept further speed changes only when repeat runs improve their target metric
without reducing arbitrary-start success, map-frame pose correctness, or recovery.
