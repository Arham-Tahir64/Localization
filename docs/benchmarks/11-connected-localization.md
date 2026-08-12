# Connected localization contract benchmark

Date: 2026-08-11

## Scope

This benchmark measures only deterministic client contract overhead on the Mac
host: JSON payload sizes, schema validation, rigid pose composition, and JSON
encoding. It does **not** measure iPhone JPEG encoding, Wi-Fi, model inference,
PnP accuracy, relocalization recall, thermal load, or battery use.

Reproduce from the repository root:

```sh
xcrun swiftc -O \
  -module-cache-path /tmp/HouseMapperSwiftModuleCache \
  -Xcc -fmodules-cache-path=/tmp/HouseMapperClangModuleCache \
  -o /tmp/connected-localization-benchmark \
  HouseMapper/Models/CoordinateFrames.swift \
  HouseMapper/Models/MapMetadata.swift \
  HouseMapper/Models/FrameObservation.swift \
  HouseMapper/Models/ServerLocalization.swift \
  Benchmarks/ConnectedLocalizationBenchmark.swift
/tmp/connected-localization-benchmark
```

Host: macOS 26.3.1 build 25D2128. Optimized Swift build.

## Results

| Operation | Iterations | Total | Mean |
|---|---:|---:|---:|
| Manifest decode + validation | 20,000 | 187.176 ms | 9,359 ns |
| 64-inlier response decode + 2D/3D reprojection validation | 50,000 | 7,353.974 ms | 147,079 ns |
| `T_map_world` pose bridge | 100,000 | 4.223 ms | 42.2 ns |
| 250 KB JPEG request JSON encode | 500 | 218.161 ms | 436,322 ns |

Payload sizes:

- manifest: 605 bytes;
- request with a 250,000-byte synthetic JPEG: 333,807 bytes;
- response with 64 verified 2D/3D inliers: 5,292 bytes.

Base64 JSON expands the 250 KB JPEG request by about 33.5%. That is acceptable
for the correctness-first proof of concept but is a measurable optimization
target. A binary multipart or CBOR media body can remove most of that expansion
after server interoperability is proven.

## Interpretation

Coordinate composition and validation are far below a frame budget. The real
latency budget will be dominated by CI JPEG generation, network round trip,
image retrieval, local feature extraction/matching, and PnP/RANSAC. The app
therefore rate-limits to one request in flight and at least 0.75 seconds between
initial queries, then at least 2 seconds between maintenance queries.

## Required iPhone/server benchmark

For each saved map revision, test at least five arbitrary starts per room and
record:

- success recall within 5, 10, 20, and 45 seconds;
- false-positive count, including changed and unmapped scenes;
- median/p95 server round trip;
- retrieval, matching, and PnP time separately on the server;
- inlier count/ratio and median reprojection error;
- translation and rotation error at surveyed physical checkpoints;
- pose jitter while stationary and during a repeated route;
- recovery time after occlusion and rapid motion;
- iPhone FPS, thermal state, memory, battery per 15 minutes, and JPEG time;
- query/request/response bytes and Wi-Fi loss behavior.

HouseMapper now records connected query count, failures, rejections,
confirmations, round-trip duration, and latest PnP quality in its session
benchmark. Those device reports are the evidence needed for the next tuning
iteration.
