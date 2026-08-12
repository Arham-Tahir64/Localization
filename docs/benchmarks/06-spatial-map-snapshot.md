# Spatial-map snapshot persistence benchmark

Date: 2026-08-11

## Question

What are the host encode/decode cost and package-size impact of preserving every
exposed 3D ARKit landmark and identifier in a validated binary sidecar?

## Method

`Benchmarks/SpatialMapSnapshot/main.swift` builds deterministic 10k- and
100k-landmark snapshots, encodes them using the production binary property-list
codec, decodes them with map-ID/bounds/identifier validation, and asserts exact
structural equality.

```sh
xcrun swiftc -O -module-cache-path /tmp/HouseMapperSwiftModuleCache \
  HouseMapper/Models/MapMetadata.swift \
  Benchmarks/SpatialMapSnapshot/main.swift \
  -o /tmp/housemapper-spatial-map-benchmark
/tmp/housemapper-spatial-map-benchmark
```

Host: arm64 Mac, macOS 26.3.1 (25D2128), Apple Swift 6.3.3. Results are single-run
host measurements, not iPhone 16 Pro latency or energy claims.

## Raw results

| Landmarks | Encoded bytes | Encode | Decode + validation |
| ---: | ---: | ---: | ---: |
| 10,000 | 508,334 | 35.725 ms | 43.485 ms |
| 100,000 | 6,108,464 | 186.119 ms | 347.544 ms |

Both decoded snapshots were exactly equal to their inputs. The codec rejects a map
ID mismatch, duplicate identifier, nonfinite coordinate, unsupported schema, or
bounds inconsistent with the landmark payload.

## Interpretation and decision

The 10k case is small enough for an app-owned fidelity sidecar, but encoding and
especially 100k validation must remain off the main actor. The current `MapLibrary`
already stages package I/O in a detached task, so the new sidecar follows that path.

Binary property lists are adequate for the current ARWorldMap-scale proof of
concept. Before accepting server maps with hundreds of thousands or millions of
landmarks, replace the plist with a chunked binary schema that supports mapped I/O,
checksums, versioned sections, and render LOD without decoding the whole map.
