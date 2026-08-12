# Spatial console benchmark

This benchmark covers the exact deterministic landmark level-of-detail path used
by the map-dominant SceneKit console. It does not estimate SceneKit GPU cost and it
does not substitute for an Instruments run on the iPhone 16 Pro.

## Workload

- Input: 50,000 deterministic 3D landmarks, equal to the mapping accumulator cap.
- Output: 12,000 spatially distributed landmarks, equal to the console display cap.
- Warm-up: 5 iterations.
- Recorded: 100 iterations, release-optimized host executable.
- Source: `Benchmarks/SpatialConsoleBenchmark/main.swift`, compiled together with
  the production `MapMetadata.swift` and `FeaturePointSnapshot.swift` sources.

## Results

Measured on the development Mac on 2026-08-11:

| Metric | Result |
| --- | ---: |
| Median | 1.782 ms |
| p95 | 2.713 ms |
| Maximum | 2.911 ms |

Run `scripts/benchmark-spatial-console.sh` to refresh the recorded values after a
render-model change. The checksum was `16353735600`. Host timings and device-render
timings must be reported separately.

## Device checks still required

Profile the relocalization screen on the iPhone 16 Pro with a large saved map. Log
Core Animation FPS, SceneKit renderer CPU/GPU time, peak memory, thermal state, and
the count of gray and green points. Accept 12,000 as the production budget only if
the interface remains responsive while ARKit and connected localization are both
active; otherwise tune the cap using device evidence.
