# Camera-first mapping and relocalization experience

This implementation adapts the supplied point-cloud localization reference to a
phone-sized live AR workspace. It does not reproduce the reference post's reported
mall-scale accuracy or pose-jitter claims; those describe another capture system,
map, localizer, and evaluation.

## Existing pipeline retained

`ARSCNView` remains the only camera renderer and `ARSessionController` remains the
owner of ARKit world tracking, LiDAR depth, scene reconstruction, map coverage,
`ARWorldMap` persistence, origin-anchor gating, and 6DoF output. Saving and opening
maps are unchanged. The redesign is an additional UI projection of real AR data,
not a second tracker or a cosmetic simulation.

## Visual states

| State | Point treatment | Pose behavior | Primary prompt |
| --- | --- | --- | --- |
| Mapping | Cyan current `rawFeaturePoints` | Current ARKit mapping pose | Scan architectural detail |
| Relocalizing | Muted white current points; saved identifier overlaps bright green | Withheld | Match this view to the saved map |
| Localized | Green current tracking-support points; saved identifier overlaps brighter/larger | Published in saved-map coordinates | Localized in saved map |
| Limited/interrupted | Muted live points and amber/red status | Withheld | Slow down or find textured mapped detail |

ARKit exposes feature-point identifiers, but does not expose its private descriptor
matches or relocalization inlier set. Therefore an identifier overlap is labelled as
such, while other green points are described as localized tracking support only
after the existing normal-tracking plus restored-origin gate succeeds.

## Rendering design

- `ARFrame.rawFeaturePoints` are sampled deterministically to at most 240 points.
- Saved-map identity overlaps are retained as priority samples.
- World points behind the camera or outside the viewport are rejected.
- `ARCamera.projectPoint` converts accepted points to normalized screen positions.
- Snapshots publish at no more than 10 Hz; ARKit tracking continues at its native
  frame rate.
- SwiftUI `Canvas` batches each semantic point role into one path/fill instead of
  creating a view per feature.
- SceneKit's generic debug feature overlay is disabled to avoid duplicate points;
  the real reconstructed mesh remains visible at reduced opacity.

The UI uses a full-bleed camera, compact status capsule, scanning reticle, saved-map
reference thumbnail, map inset, and heading/pose instrument. Motion is limited to
the scanning sweep, short status transitions, and a one-shot localization pulse.
