# HouseMapper

HouseMapper is a native, offline iOS proof of concept for this pipeline:

> scan an indoor space → save a persistent map → terminate the app → reopen the map → relocalize → track a 6DoF camera pose in map coordinates

The first implementation deliberately uses ARKit's `ARWorldMap` as the localization backend. It also records map metadata and exposes tracking, mapping, depth, and confidence diagnostics so that real-device testing can decide whether a custom place-recognition fallback is justified.

## Read this first

- [ARKit and iPhone research](docs/01-arkit-research.md)
- [Architecture, map format, coordinate frames, and algorithms](docs/02-architecture.md)
- [Implementation and validation plan](docs/03-implementation-plan.md)

## Current proof-of-concept scope

- Native SwiftUI + ARKit/SceneKit application
- iPhone-only operation after installation
- LiDAR scene depth and scene reconstruction when supported
- Live feature points, reconstructed geometry, mapping state, tracking state, pose, and top-down coverage view
- Local `ARWorldMap` packages with metadata and a visual relocalization guide
- Reload through `initialWorldMap`, explicit relocalizing/tracking states, confidence bands, timeout, retry, and interruption recovery
- Stable saved-map pose output after ARKit has relocalized

The project requires a physical LiDAR-capable iPhone. ARKit world tracking, scene depth, and relocalization cannot be meaningfully validated in Simulator.
