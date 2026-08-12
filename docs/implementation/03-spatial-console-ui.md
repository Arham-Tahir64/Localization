# Spatial console UI implementation

## Reference mapping

The target reference is an instrumentation-first relocalization console rather
than a camera-first AR HUD. The implemented hierarchy mirrors its major regions:

| Reference region | HouseMapper implementation | Production data |
| --- | --- | --- |
| Large gray/green 3D cloud | `SpatialPointCloudView` | Saved or live ARKit landmarks; current verified support points |
| Live video pane | `ARSceneView` plus `SpatialFeatureOverlay` | Current AR frame and projected ARKit/server observations |
| Route map | `MapOverviewView` | Map landmarks, LiDAR mesh edges, map-frame pose trail |
| Attitude gauge | `AttitudeInstrumentView` | Map-frame pitch and roll |
| Heading gauge | `MapHeadingInstrumentView` | Map-frame yaw, explicitly not magnetic north |
| Relocalization state | Compact top status rail | State machine, tracking, feature, and server status |

## Visual truth rules

- Gray points are stored or accumulated 3D landmarks.
- During native ARWorldMap relocalization, green 3D points require a current raw
  feature identifier that also exists in the saved map.
- During connected localization, green 3D points are exactly the server-returned
  verified PnP inliers in map coordinates.
- Seeking observations remain white. Mapping observations remain cyan. A status
  label alone never turns point geometry green.
- The heading dial is labeled map heading because ARKit map yaw is not guaranteed
  to be magnetic or geographic north.

## Layout and interaction

The map owns roughly 64% of the workspace. The right rail contains live video,
route, paired attitude/heading instruments, and one compact session action.
Portrait remains supported, but landscape is enabled and most closely matches the
reference. The point-cloud viewport supports SceneKit orbit/zoom gestures.

## Performance design

The point cloud uses two batched SceneKit point primitives (gray map and green
support), not one SwiftUI view or draw call per point. The map display cap is
12,000 spatially distributed points from at most 50,000 retained landmarks. Green
support geometry updates only when its point set changes. The top-down route keeps
its existing bounded Canvas path. See `docs/benchmarks/06-spatial-console.md`.

## Physical validation

On iPhone 16 Pro, compare portrait and landscape with a saved whole-house map.
Verify that the camera inset projection aligns, gray cloud orbit remains smooth,
green points appear only after a confirmed native/server localization, and the
pose trail and instruments move in the same saved-map frame. Capture screenshots
and an Instruments trace before changing the 12,000-point production budget.
