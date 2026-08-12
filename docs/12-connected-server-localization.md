# Connected server localization client

Date: 2026-08-11

## Outcome

HouseMapper now has a real, opt-in connected relocalization path. Native
`ARWorldMap` relocalization remains the first attempt and offline fallback. A
saved map can additionally carry a versioned `server-map.json`; if native
relocalization has not succeeded after 10 seconds, the app starts a clean
ARKit visual-inertial world and queries that selected server map.

This is not a mock localizer. The iPhone client never manufactures feature
correspondences or a pose. It accepts a map pose only when the server returns:

- the exact map ID and immutable server map version;
- the exact session ID, frame ID, and ARFrame timestamp;
- a rigid `T_map_camera` in metres, right-handed, Y-up coordinates;
- at least 40 real PnP inliers and a 0.25 inlier ratio;
- at most 3 pixels median reprojection error;
- one unique 3D map landmark for every displayed green inlier; and
- client-side reprojection of every 3D landmark through the reported pose and
  intrinsics, with each residual below 8 pixels and independently measured
  median below 3 pixels; and
- two temporally close, mutually consistent `T_map_world` estimates.

The resulting bridge is computed for the matched frame as:

```text
T_map_world = T_map_camera * inverse(T_world_camera)
T_map_currentCamera = T_map_world * T_world_currentCamera
```

ARKit then supplies low-latency local VIO between server results. Confirmed
server results refresh the bridge at a bounded maintenance rate. Failed or weak
maintenance queries retain the last good bridge; they never overwrite it.

## Map-package contract

The desktop map builder receives the complete shared package, including:

- `metadata.json`
- `worldmap.arexperience`
- `spatial-map.plist`
- `preview.jpg`
- `keyframes/manifest.json`
- calibrated JPEG keyframes
- `benchmark.json` when available

After COLMAP/HLoc-style reconstruction, it creates `server-map.json`:

```json
{
  "schemaVersion": 1,
  "map": {
    "mapID": "THE-UUID-FROM-METADATA",
    "versionID": "IMMUTABLE-SERVER-RECONSTRUCTION-UUID"
  },
  "createdAt": "2026-08-11T20:00:00Z",
  "queryEndpoint": "http://mapping-mac.local:8080/localize",
  "frameConvention": "T_map_camera-right-handed-y-up-meters",
  "models": {
    "reconstruction": "COLMAP-3.13",
    "retrieval": "NetVLAD",
    "localFeatures": "SuperPoint",
    "matcher": "LightGlue"
  },
  "query": {
    "maximumImageWidth": 1280,
    "jpegQuality": 0.8,
    "minimumQueryInterval": 0.75,
    "requestTimeout": 8
  }
}
```

On iPhone, use the saved map's ellipsis menu and select **Attach Server
Localization Map**. Import is size-bounded, map-ID-bound, validated, and atomic.
It cannot replace another map's manifest.

Only HTTPS endpoints are accepted on the internet. Plain HTTP is accepted only
for a Bonjour `.local` computer name. Credentials, query strings, fragments,
and HTTP redirects are rejected. HouseMapper stores no server credential.

## Request and response

The app sends `application/json`. `jpegImage` is standard Codable Base64 data.
The observation contains the scaled camera intrinsics and exact
`T_world_camera` for the same native landscape camera image. Image orientation
is `.right` (portrait display rotates the native buffer clockwise).

Schema 1 sends JPEG only. It deliberately sets `depth` to `null` and accepts
only `visualPnP`. A server claim of `visualAndDepth` is rejected because no
synchronized depth samples exist in this schema. A later schema must carry the
actual depth array and calibration before depth verification is truthful.

The response contains the `ServerLocalizationResult` plus a list of verified
inliers. Every inlier has encoded-image `x/y`, a unique map landmark ID, and its
metric 3D position in the server map frame. After pose confirmation, HouseMapper
transforms and reprojects those 3D landmarks each AR frame. Green points
therefore remain attached to geometry instead of being stale network-frame dots.

## UI states

- **Native map first:** orange, seeking the saved ARWorldMap.
- **Starting local VIO:** orange, native map was not found in the first window.
- **Matching calibrated view:** orange, one bounded server query is in flight.
- **PnP match 1 of 2:** orange; pose still withheld.
- **Localized:** green; only verified PnP landmarks are green for this path.
- **Weak/rejected result:** no new pose or green points.
- **Timed out:** red after the shared 45-second attempt window.

## Server implementation

The compatible desktop builder and `/localize` service are now implemented in
`server/`: exact package validation, metric learned-feature triangulation,
map-specific retrieval, ALIKED/LightGlue local matching, PnP/RANSAC/refinement,
real inlier output, immutable checksummed maps, and bounded transport. See
`docs/13-server-localization-implementation.md` and `server/README.md`.

Schema-v2 synchronized depth verification and held-out iPhone accuracy evaluation
remain. No host synthetic benchmark in this repository claims centimetre physical
pose accuracy.
