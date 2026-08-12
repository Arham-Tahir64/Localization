# Visible-feature selection benchmark

Date: 2026-08-11

## Question

Can the overlay select a deterministic, spatially distributed subset **after**
visibility filtering without making selection itself a likely frame bottleneck?

## Method

The repository benchmark at `Benchmarks/FeatureSelection/main.swift` constructs
deterministic normalized visible candidates, retains 24 priority identifiers, and
selects 240 candidates. The optimized command was:

```sh
xcrun swiftc -O -module-cache-path /tmp/HouseMapperSwiftModuleCache \
  HouseMapper/Models/MapMetadata.swift \
  HouseMapper/Models/FeaturePointSnapshot.swift \
  Benchmarks/FeatureSelection/main.swift \
  -o /tmp/housemapper-feature-selection-benchmark
/tmp/housemapper-feature-selection-benchmark
```

Host: arm64 Mac, macOS 26.3.1 (25D2128), Apple Swift 6.3.3. These are host
microbenchmarks, not iPhone 16 Pro frame-time claims.

## Raw results

| Visible candidates | Iterations | Mean selection time |
| ---: | ---: | ---: |
| 1,000 | 500 | 0.0446 ms |
| 5,000 | 200 | 0.1389 ms |
| 20,000 | 80 | 0.5011 ms |
| 100,000 | 20 | 2.4716 ms |

Every iteration returned 240 unique selected candidates; the checksum in the raw
run matched `iterations × 240` for every case.

## Interpretation and decision

Selection is linear in visible input and remained approximately 0.5 ms on this host
through 20,000 candidates. This supports moving selection after projection/visibility
filtering. It does **not** benchmark ARKit projection, SwiftUI publication, Canvas
drawing, GPU composition, energy, or thermals.

The initial shipping cap remains 240 for this slice because the defect was wasted
budget, not an evidence-backed render-cap problem. The corrected path can now fill
that budget with visible real landmarks. A higher cap requires the documented
iPhone signpost and rendering comparison; it will not be justified by this selector
microbenchmark alone.
