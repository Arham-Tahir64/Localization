# Metric learned-feature server implementation

Date: 2026-08-11

## Outcome

The previously missing connected backend is now implemented under `server/`.
HouseMapper can export calibrated mapping keyframes, build a persistent metric
learned-feature map on a computer, attach the generated immutable map manifest on
the iPhone, and request geometrically verified 6DoF poses.

This closes the software gap between the earlier verified iPhone client and an
actual `/localize` service. It does **not** yet prove the reference post's 1.7 cm
jitter or 99.9% recall; those are claims about a much larger proprietary data set
and must be measured independently on held-out HouseMapper walks.

## Map construction

1. Fail-closed parsing preserves every calibrated JPEG, intrinsic matrix, and
   `T_map_camera` from `keyframes/manifest.json`.
2. ALIKED-n16rot extracts up to 4,096 learned features per 1,280-pixel keyframe.
3. Candidate pairs combine temporal neighbors, saved-pose neighbors, and visual
   descriptor neighbors, which supports hallway loops as well as local overlap.
4. Accuracy-mode LightGlue matches each candidate pair.
5. Each pair is triangulated directly using the saved metric poses. A match must
   have at least 1.25° parallax, positive depth in both cameras, ≤6 px maximum
   reprojection residual, and ≤2.5 px pair median residual.
6. Track union rejects two observations from the same keyframe. The accepted view
   graph must connect every keyframe.
7. Multi-view tracks are triangulated again with all observations. The map refuses
   to save unless at least 80 persistent landmarks survive.
8. Persistent landmark positions remain in the original ARKit map frame; there is
   no unobservable SfM similarity transform that could change scale or orientation.
9. A 32-word, map-trained VLAD index provides coarse retrieval. The immutable map
   stores each keyframe observation, descriptor, landmark association, persistent
   3D point, track length, and model identity.

The map is staged and atomically renamed. `map.npz` is SHA-256 checksummed and
bounded by compressed size, uncompressed size, array count, shapes, dtypes,
keypoint/landmark counts, and cross-references on every load.

## Query localization

1. The service validates the exact map version, session/frame/timestamp, native
   image geometry, intrinsics, `T_world_camera`, tracking state, and JPEG.
2. Query ALIKED features produce the map-specific VLAD descriptor.
3. The top ten keyframes are retrieved.
4. Accuracy-mode LightGlue matches the query against each retrieved keyframe.
5. Repeated observations of the same persistent landmark vote for one query↔map
   association. Ambiguous associations are removed, and landmark IDs remain unique.
6. At least 50 correspondences enter AP3P RANSAC; OpenCV LM then refines the pose.
7. The server requires ≥40 inliers, ≥0.25 ratio, ≤3 px upper-median reprojection
   error, and ≤6 px per retained inlier.
8. The response includes the exact query 2D pixel and metric map 3D point for every
   accepted inlier. Schema v1 truthfully reports `visualPnP`, never depth.
9. The iPhone independently reprojects every point and requires two consistent
   `T_map_world` results before publishing pose or green inliers.

Coordinate conversion is explicit:

```text
ARKit camera: +X right, +Y up, looks down -Z
OpenCV camera: +X right, +Y down, looks down +Z

T_cvCamera_map = diag(1, -1, -1, 1) · inverse(T_map_arCamera)
```

Deterministic tests recover known metric camera poses and triangulated points using
this exact conversion.

## Reproducibility and model identity

- LightGlue source is pinned to commit
  `eb42fee2d71449efb0aa5c10549752b5d75384d8`.
- ALIKED-n16rot weight SHA-256:
  `ddf3abbf38e86f6a74540d214e1a9712c54b2d8551abc864542199f2347d7332`.
- ALIKED LightGlue weight SHA-256:
  `d975e965b105311a6143194852297dff4f02aea5cc2e10cecfed966ca0e22503`.
- The runtime hashes loaded tensor states into the immutable map manifest. A server
  with any different feature or matcher identity refuses to open that map.

## Verification

Python 3.12 test environment using the exact dependency versions pinned in
`server/pyproject.toml`:

- 19 tests passed;
- metric three-view triangulation and low-parallax rejection;
- 6DoF RANSAC PnP with 20% outliers and ARKit/OpenCV roundtrip;
- package preservation plus extra-file, dimension, and symlink rejection;
- immutable map checksum/load and metric builder/reload equivalence;
- end-to-end correspondence/PnP/response construction;
- bounded HTTP content-type, length, malformed JSON, health, and weak-result paths.

See `docs/benchmarks/12-server-localization.md` for the required performance run.

## Remaining accuracy work

Necessary:

1. build a fresh physical-house map with this version so calibrated keyframes exist;
2. collect held-out query routes from arbitrary rooms, lighting changes, and moved
   furniture, with repeatable position/orientation checkpoints;
3. report recall, false-positive rate, translation/rotation error, jitter, time to
   first confirmed pose, runtime latency distribution, and thermal behavior;
4. tune keyframe thresholds and retrieval count from those reports without lowering
   PnP/reprojection safety gates;
5. add schema-v2 synchronized LiDAR samples and truthful geometric verification if
   visual-only ambiguity remains.

Optional after evidence:

- replace JSON/Base64 queries with a framed binary request to reduce bandwidth;
- add authentication and HTTPS for non-private-LAN operation;
- use NetVLAD/MegaLoc global embeddings if map-trained local-descriptor VLAD recall
  is insufficient on held-out rooms;
- add sequence retrieval and pose-graph smoothing for long driving/global paths.
