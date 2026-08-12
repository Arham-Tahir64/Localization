# Calibrated keyframe selector benchmark

Date: 2026-08-11

## Question

Can the real-time mapping path apply metric novelty and quality gates on every AR
frame without becoming a meaningful CPU bottleneck, and what is the manifest cost
at the fixed 120-keyframe package bound?

## Method

`Benchmarks/MappingKeyframe/main.swift` runs the production selector across 216,000
deterministic 60 Hz poses with tracking/feature failures, consumes and commits each
accepted reservation, then builds and JSON-encodes a production 120-record manifest.

```sh
xcrun swiftc -O -module-cache-path /tmp/HouseMapperSwiftModuleCache \
  HouseMapper/Models/CoordinateFrames.swift \
  HouseMapper/Models/FrameObservation.swift \
  Benchmarks/MappingKeyframe/main.swift \
  -o /tmp/housemapper-keyframe-benchmark
/tmp/housemapper-keyframe-benchmark
```

Host: arm64 Mac, macOS 26.3.1 (25D2128), Apple Swift 6.3.3. These are host CPU
microbenchmarks, not iPhone 16 Pro JPEG, memory, energy, or thermal claims.

## Raw results

| Operation | Input | Result |
| --- | ---: | ---: |
| Per-frame quality/metric-novelty selector | 216,000 frames | 85.94 ns mean; 120 accepted |
| Manifest validation/build/JSON encode | 120 keyframes | 101,039 bytes; 2.843 ms |

## Decision

Keep selector math inline on the AR delegate path and JPEG encoding off-thread with
only one encode in flight. Package and image size, encode latency, dropped capture
rate, thermal state, and mapping FPS must be measured from shared physical-iPhone
benchmark packages before raising the keyframe cap or encoded resolution.
