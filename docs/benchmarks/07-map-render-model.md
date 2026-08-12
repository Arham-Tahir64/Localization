# Spatial-map render-model benchmark

Date: 2026-08-11

## Question

Can HouseMapper preserve the full 3D bounds and select a spatially distributed
4,000-landmark display LOD from the real saved map without making the model
conversion an obvious UI bottleneck?

## Method

`Benchmarks/SpatialMapRender/main.swift` builds deterministic 3D landmark arrays,
runs the production `SpatialMapRenderSnapshot.make` implementation, verifies source
and output counts, and measures repeated full-bounds plus grid-LOD construction.

```sh
xcrun swiftc -O -module-cache-path /tmp/HouseMapperSwiftModuleCache \
  HouseMapper/Models/MapMetadata.swift \
  HouseMapper/Models/FeaturePointSnapshot.swift \
  Benchmarks/SpatialMapRender/main.swift \
  -o /tmp/housemapper-spatial-map-render-benchmark
/tmp/housemapper-spatial-map-render-benchmark
```

Host: arm64 Mac, macOS 26.3.1 (25D2128), Apple Swift 6.3.3. These are
single-host CPU microbenchmarks, not iPhone 16 Pro frame-time, Canvas, GPU, thermal,
or energy measurements.

## Raw results

| Source landmarks | Iterations | Render landmarks | Mean model-build time |
| ---: | ---: | ---: | ---: |
| 10,000 | 200 | 4,000 | 0.5295 ms |
| 100,000 | 40 | 4,000 | 1.8478 ms |
| 1,000,000 | 4 | 4,000 | 10.6854 ms |

Every result retained the full source count and exact full-cloud 3D bounds while
limiting drawing input to 4,000 real landmarks. The checksum remained stable for
every iteration.

The same harness also simulated 120 mapping publications of 1,000 real
observations each, with 500 IDs overlapping the previous publication. The bounded
accumulator retained the 50,000 most recently observed IDs and averaged **4.3444
ms** per integrate-plus-4,000-point-render-snapshot operation on this host. This
includes repeated rendering-model construction and several bounded evictions.

## Interpretation and decision

The current ARWorldMap-scale path is inexpensive enough on this host at its 0.5 s
publication cadence. The live accumulator preserves landmarks after they leave the
camera while remaining bounded and contains only actual ARKit observations. The
1M case is not suitable for synchronous UI work despite being far below a frame at
this host measurement: future server-scale maps need a precomputed multiresolution
spatial index and chunked/mapped loading.

The Canvas batches landmarks into four height bands, avoiding one draw call per
point. Rendering must still be measured with Instruments on the physical iPhone;
this benchmark only supports the CPU-side LOD decision.
