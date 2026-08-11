# Step-by-step implementation and validation plan

## Product principle

Prove the smallest complete persistence loop on the physical iPhone before adding a custom SLAM stack. Every phase has a measurable exit condition.

## Phase 0 — repository and research

- Record API capabilities, limitations, map schema, coordinate notation, and fallback decision.
- Create a native iOS project with no runtime network dependency.
- Keep the localization backend behind a stable pose/status contract.

Exit: documents reviewed; project opens and builds for a physical iPhone.

## Phase 1 — ARKit tracking and LiDAR

- Run `ARWorldTrackingConfiguration` with gravity alignment.
- Enable horizontal/vertical planes, LiDAR scene depth, smoothed depth for display, and classified scene reconstruction when supported.
- Show camera, tracking reason, mapping status, depth resolution/confidence availability, feature count, and camera pose.
- Return a clear unsupported-device state instead of crashing.

Exit: walk for ten minutes without session crash or unbounded memory growth; pose/depth/mesh update on iPhone 16 Pro.

## Phase 2 — map representation and visualization

- Visualize ARKit feature points, reconstructed mesh, planes, and world origin.
- Maintain only a bounded/downsampled top-down coverage set and pose trail for UI.
- Add a named identity map-origin anchor.

Exit: multiple rooms and hallways remain in one consistent visual frame; revisiting a loop does not visibly produce catastrophic misalignment.

## Phase 3 — persistence

- Permit save when mapping is `.extending` or `.mapped` and tracking is usable.
- Capture `ARWorldMap`, append/verify the origin anchor, and secure-archive it.
- Write an atomic UUID map package with metadata and a final camera preview.
- List packages on Home after save.

Exit: force-quitting does not remove the package; incomplete writes do not appear as valid maps.

## Phase 4 — reload

- Secure-unarchive the chosen map.
- Configure the same world alignment/features and set `initialWorldMap`.
- Show saved extent/points immediately in the overview but do not publish a current map pose yet.

Exit: archive round-trip succeeds across a normal app restart on the same supported iOS version.

## Phase 5 — arbitrary-start relocalization

- Start tests in each mapped room with several headings and heights.
- Show `.relocalizing`, guide imagery, elapsed time, and slow-scan instructions.
- Require `.normal` plus restored origin before declaring localized.
- Time out into an explicit recoverable failure rather than reporting local-session coordinates.

Exit: collect a result row for every start: success/failure, latency, initial pose error, lighting, scene changes, and map size.

## Phase 6 — continuous map-relative tracking

- Publish `T_M_C`, XYZ, pitch/yaw/roll, and overview position only after localization.
- Keep a bounded trajectory in M.
- Mark poses stale/unavailable while tracking is limited.

Exit: walk a closed route through the house and compare return-to-start pose drift at fixed checkpoints.

## Phase 7 — tracking-loss detection and recovery

- Handle camera tracking reasons, session interruptions, failures, thermal changes, and background/foreground transitions.
- Return `true` from `sessionShouldAttemptRelocalization`.
- Provide retry-from-saved-map and cancel actions.
- Never silently reset into a new coordinate system while claiming map tracking.

Exit: cover camera briefly, move through a textureless area, background/foreground the app, and recover or fail explicitly.

## Phase 8 — robustness decision

Run a repeatable matrix:

- daytime, nighttime, lights switched;
- doors open/closed;
- movable furniture rearranged;
- starting in every room and hallway in multiple headings;
- slow and moderately fast motion;
- one day and one week after mapping;
- repeated-looking locations and blank walls.

If ARWorldMap meets the defined recall, latency, error, and zero-wrong-room criteria, stop. Complexity avoided is a feature.

If it does not, implement the versioned custom keyframe/depth sidecar in this order:

1. sparse keyframe capture and storage budgets;
2. global visual retrieval;
3. local 2D↔3D matching and PnP/RANSAC;
4. LiDAR/depth geometric verification;
5. multi-frame confidence and rejection;
6. recovery integration and map maintenance.

## Test protocol

At least six surveyed checkpoints should be marked physically but need no operational hardware after evaluation. For each map revision, run at least five starts per room. Report median/p95 translation and rotation error, success recall, time-to-localize, false-positive count, peak resident memory, thermal state, battery drain per 15 minutes, and map package size.

## Current implementation boundary

The first code delivery covers the working ARWorldMap path through Phase 7 and the instrumentation needed to decide Phase 8. It intentionally does not add OpenCV/Core ML local features, RoomPlan, cloud sync, raw video storage, or a custom SLAM engine.
