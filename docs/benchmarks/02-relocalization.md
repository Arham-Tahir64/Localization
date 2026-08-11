# Relocalization Logic Stress Findings

**Scope.** This report covers deterministic, host-side checks of
`RelocalizationStateMachine` and `CoordinateFrames` only. It does not measure
ARKit map matching, LiDAR quality, camera tracking, pose accuracy, or iPhone
performance.

## Test artifact

`HouseMapperTests/RelocalizationStressTests.swift` adds seven deterministic
XCTest cases:

1. Origin-anchor arrival and loss ordering.
2. The exact 45-second timeout boundary.
3. Negative, `NaN`, and negative-infinity elapsed-time inputs.
4. A fixed-seed, 10,000-update adversarial state sequence.
5. Confirmation latency at 30 versus 60 updates per second.
6. 500 fixed-seed rigid-transform composition/inversion trials.
7. An XCTest performance measurement over 100,000 state updates.

The project uses explicit source-file entries in its Xcode project. Per the
worker scope, this report does not edit `project.pbxproj`; consequently the new
test file must be registered in the `HouseMapperTests` target by the integrating
orchestrator before Xcode will discover and run it.

**Integration status:** the orchestrator subsequently registered this file in the
`HouseMapperTests` target and implemented the duration/timing recommendations. See
`04-orchestrator-synthesis.md` for the resolution.

## Executed host check

The following temporary-shim command type-checked the actual checked-in state
machine body (with only its unavailable `Foundation` import removed and the
application enums replaced by equivalent harness enums):

```sh
{ sed -n '1,240p' /tmp/relocalization-harness.8bqW0x/Shim.swift; \
  sed '1d' HouseMapper/Models/RelocalizationStateMachine.swift; \
  sed -n '1,240p' /tmp/relocalization-harness.8bqW0x/main.swift; } \
  | swiftc -typecheck -
```

Result: exit code 0; no compiler diagnostics.

An executable benchmark could not be run in this environment. The active
developer directory is Command Line Tools rather than a full Xcode install:
`xcodebuild -version` reports that condition, and linking the temporary Swift
harness fails with `ld: library 'System' not found`. The direct unmodified
source compile also cannot import `Foundation` without a selected macOS SDK.
Therefore this report intentionally records no host throughput, XCTest timing,
or device-performance number.

## Findings

### 1. Confidence confirmation is frame-rate dependent (actionable)

The state machine raises medium confidence after 15 normal/origin-present
updates and high confidence after 60. That is 0.50 s / 2.00 s at 30 FPS, but
0.25 s / 1.00 s at 60 FPS. Update jitter or dropped frames change those delays
as well. This is deterministic logic behavior, not an ARKit accuracy result.

**Recommendation (highest priority):** replace the frame-count confidence
thresholds with an elapsed duration of uninterrupted valid tracking, or pass a
monotonic timestamp/delta into the state machine. Keep frame counts only as
secondary diagnostic telemetry.

### 2. Invalid elapsed input bypasses the timeout (actionable)

`elapsedTime >= timeout` is false for `NaN`, negative values, and negative
infinity. The current machine therefore continues relocalizing for those inputs
instead of failing. Production normally derives elapsed time from a monotonic
clock, but the state-machine API accepts arbitrary `TimeInterval` values.

**Recommendation (high priority):** enforce `elapsedTime.isFinite &&
elapsedTime >= 0` at the controller boundary and defensively inside the state
machine. Choose and test one policy for invalid input: fail immediately with a
diagnostic reason, or clamp to the last valid elapsed value. Do not silently
allow an unbounded attempt.

### 3. Deadline wins over a valid match at exactly 45 seconds (decision needed)

On an unlocalized machine, a `.normal` update with the origin present at exactly
45 seconds produces `.failed/.timedOut`; the state switch is not evaluated.
This is internally consistent with the existing unit tests, but it makes the
deadline an exclusive boundary.

**Recommendation (medium priority):** decide whether a match reported in the
same callback as the deadline should succeed. If yes, evaluate valid normal
tracking/origin before the timeout check or define a small timer grace period.

### 4. A successful session can remain relocalizing indefinitely after later loss (policy review)

After `hasLocalized` becomes true, the initial 45-second timeout is permanently
disabled. This matches the existing test suite and can be correct for transient
tracking loss, but it leaves no bounded retry policy for a prolonged loss after
initial localization.

**Recommendation (medium priority):** add a distinct post-localization recovery
deadline or explicit user retry/cancel action, and record it separately from
the initial-load timeout.

### 5. Transform formulas are algebraically sound for rigid transforms

The added stress test generates 500 deterministic rotation/translation pairs
and verifies all three relationships: `T_M_C = T_M_W * T_W_C`, recovery of
`T_M_W` from a global match, and `T_W_C * inverse(T_W_C) = I`. It is ready for
Xcode execution; no numerical-error maximum is claimed until it has executed
on the target toolchain.

## Physical arbitrary-start benchmark protocol

Run this on an iPhone 16 Pro after registering the stress file and adding
production telemetry for all timestamps. Repeat after any map-format,
relocalization-policy, or performance change.

1. Create three maps: a small room, an open living area, and a multi-room
   house section. For each, record lighting, layout, map size, and scan route.
2. Define 12 marked start positions per map: four familiar locations, four
   adjacent-room/doorway locations, and four arbitrary positions. Use three
   headings at each mark and randomized trial order.
3. Run at least three cold-load trials per position/heading. Restart the AR
   session each trial and begin without walking to the scan origin first.
4. Record load start, first normal tracking, origin-anchor arrival, first
   published map-frame pose, medium/high confidence, timeout/cancel, and all
   tracking-loss/recovery intervals. Record tracking-state samples, not just
   the final result.
5. At marked locations, compare map-frame position and yaw against surveyed
   reference markers. Report median, p90, and worst-case position/yaw error;
   report success-within-45-s rate and time-to-first-valid-pose separately.
6. For successful trials, deliberately cover the camera or walk through a
   low-texture area, then measure recovery rate and recovery latency. Run a
   second pass under materially changed lighting and modest moved furniture.
7. During a 30-minute mixed mapping/relocalization soak, capture thermal state,
   memory footprint, process CPU, rendering FPS, map-package size, and failures.
   Report per-map aggregates and raw trial rows so the arbitrary-start recall
   cannot be hidden by averages.

**Acceptance gates to define before testing:** minimum arbitrary-start success
rate, maximum time-to-first-valid-pose, p90 position/yaw error, post-loss
recovery rate, and allowable thermal/FPS degradation. Host logic tests cannot
set or validate these values.
