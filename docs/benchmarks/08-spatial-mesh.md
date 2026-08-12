# Spatial mesh persistence and render-model benchmark

Date: 2026-08-11

## Question

What are the persistence and CPU render-LOD costs of preserving the real ARKit
scene-reconstruction mesh—anchor transforms, vertices, normals, triangle indices,
and per-face classifications—in the app-owned saved map?

## Method

`Benchmarks/SpatialMesh/main.swift` constructs deterministic classified grid meshes
at approximately 10k and 100k triangles. It uses the production schema and binary
property-list codec, asserts exact decode equality, and repeatedly constructs the
production 1,500-triangle render LOD while retaining full source bounds.

```sh
xcrun swiftc -O -module-cache-path /tmp/HouseMapperSwiftModuleCache \
  HouseMapper/Models/MapMetadata.swift \
  HouseMapper/Models/FeaturePointSnapshot.swift \
  Benchmarks/SpatialMesh/main.swift \
  -o /tmp/housemapper-spatial-mesh-benchmark
/tmp/housemapper-spatial-mesh-benchmark
```

Host: arm64 Mac, macOS 26.3.1 (25D2128), Apple Swift 6.3.3. These are
single-run host CPU measurements, not iPhone 16 Pro latency, memory, energy,
Canvas, GPU, or thermal claims.

## Raw results

| Triangles | Vertices | Encoded bytes | Encode | Decode + validation | 1,500-triangle model LOD |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10,082 | 5,184 | 441,110 | 44.572 ms | 54.238 ms | 0.0109 ms |
| 100,352 | 50,625 | 5,949,987 | 240.510 ms | 481.190 ms | 0.1061 ms |

Both decoded snapshots were exactly equal to their inputs. Validation includes
rigid map-from-anchor transforms, finite vertices/normals, matching normal counts,
unique anchor IDs, in-range triangle indices, supported classification values, map
ID, and exact full landmark-plus-mesh bounds.

## Interpretation and decision

The real reconstructed surface is now retained rather than replaced with a point
cloud or fabricated outline. The 100k-triangle plist is already about 5.95 MB and
costs roughly half a second to decode and validate on this host, so persistence
continues on a detached task and drawing receives a bounded deterministic LOD.

This representation is appropriate for ARWorldMap-scale proof-of-concept maps.
Larger server maps require a chunked binary mesh with section checksums,
memory-mapped access, and precomputed spatial LODs rather than one monolithic
property list. Physical-device Instruments measurements remain required before
raising the 1,500-triangle draw cap.
