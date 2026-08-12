# Session telemetry overhead benchmark

Date: 2026-08-11

## Question

Does collecting real per-frame tracking/camera counts and 10 Hz aggregate feature
diagnostics introduce meaningful CPU work before physical-device profiling?

## Method

`Benchmarks/SessionBenchmark/main.swift` uses the production accumulator for one
million frame samples and 100,000 full feature snapshots, consumes the resulting
report to prevent dead-code elimination, and repeatedly encodes its production
pretty/sorted JSON format.

```sh
xcrun swiftc -O -module-cache-path /tmp/HouseMapperSwiftModuleCache \
  HouseMapper/Models/MapMetadata.swift \
  HouseMapper/Models/FeaturePointSnapshot.swift \
  HouseMapper/Models/ValidationRecord.swift \
  Benchmarks/SessionBenchmark/main.swift \
  -o /tmp/housemapper-session-benchmark
/tmp/housemapper-session-benchmark
```

Host: arm64 Mac, macOS 26.3.1 (25D2128), Apple Swift 6.3.3. These are host CPU
microbenchmarks—not iPhone 16 Pro latency, energy, memory, or thermal claims.

## Raw results

| Operation | Iterations | Mean |
| --- | ---: | ---: |
| Frame/camera/tracking aggregate | 1,000,000 | 30.65 ns |
| Feature/rejection aggregate | 100,000 | 12.29 ns |
| Encode 527-byte benchmark JSON | 10,000 | 0.0088 ms |

The production depth confidence map is sampled once per second and its result is
shared between the UI label and benchmark report; the benchmark does not emulate
Core Video buffer access. That cost must be measured on the iPhone with Instruments.

## Decision

Keep aggregation inline with the existing delegate cadence because it performs
fixed scalar updates and no per-frame I/O. Persist only on map save or validation
completion. The report exposes the evidence needed to decide whether future work
belongs in feature acquisition, projection/filtering, visualization LOD, motion
guidance, or server fallback instead of guessing from dot density.
