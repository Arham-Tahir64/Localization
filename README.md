# HouseMapper

HouseMapper is a native, offline-first iOS proof of concept with an optional
computer-assisted accuracy path for this pipeline:

> scan an indoor space → save a persistent map → terminate the app → reopen the map → relocalize → track a 6DoF camera pose in map coordinates

The first implementation deliberately uses ARKit's `ARWorldMap` as the localization backend. It also records map metadata and exposes tracking, mapping, depth, and confidence diagnostics so that real-device testing can decide whether a custom place-recognition fallback is justified.

## Read this first

- [ARKit and iPhone research](docs/01-arkit-research.md)
- [Architecture, map format, coordinate frames, and algorithms](docs/02-architecture.md)
- [Implementation and validation plan](docs/03-implementation-plan.md)
- [Benchmark findings and optimization synthesis](docs/benchmarks/04-orchestrator-synthesis.md)
- [2026 localization research: on-device and server-assisted](docs/research/04-sota-localization-2026.md)
- [Metric learned-feature server implementation](docs/13-server-localization-implementation.md)
- [Connected server setup and operation](server/README.md)

## Current proof-of-concept scope

- Native SwiftUI + ARKit/SceneKit application
- iPhone-only operation after installation
- LiDAR scene depth and scene reconstruction when supported
- Live feature points, reconstructed geometry, mapping state, tracking state, pose, and top-down coverage view
- Camera-first spatial HUD with projected ARKit features: cyan while mapping, muted while seeking, and green only for saved-ID overlap or a verified localized track
- Local `ARWorldMap` packages with metadata and a visual relocalization guide
- Reload through `initialWorldMap`, explicit relocalizing/tracking states, confidence bands, timeout, retry, and interruption recovery
- Stable saved-map pose output after ARKit has relocalized
- Opt-in connected relocalization client: calibrated JPEG queries, immutable server-map identity, strict PnP/inlier verification, temporal pose confirmation, and ARKit VIO handoff
- Atomic `server-map.json` import per saved map; native `ARWorldMap` stays the offline-first path
- Computer backend for calibrated package validation, metric ALIKED/LightGlue map
  construction, map-specific retrieval, verified PnP, and real green 2D↔3D inliers

The project requires a physical LiDAR-capable iPhone. ARKit world tracking, scene depth, and relocalization cannot be meaningfully validated in Simulator.

## Build

1. Open `HouseMapper.xcodeproj` in Xcode 16 or newer.
2. Select the `HouseMapper` target and set your own development team and bundle identifier.
3. Connect the iPhone 16 Pro, trust the development computer, and select it as the run destination.
4. Build and run. Grant camera permission when prompted.

The repository's `iOS build` workflow performs an unsigned Simulator compile and compiles the coordinate-frame unit tests without depending on a hosted Simulator boot. Run the `HouseMapper` scheme's tests with Product → Test in Xcode. Physical-device testing remains mandatory for LiDAR, tracking, persistence quality, relocalization behavior, performance, and thermal measurements.
