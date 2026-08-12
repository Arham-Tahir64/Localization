# Calibrated mapping keyframe export

Date: 2026-08-11

## Purpose

ARWorldMap remains HouseMapper's native relocalization fast path. The calibrated
keyframe set is a separate, explicit input for a connected HLoc/COLMAP-style map
builder and arbitrary-start relocalizer. It avoids sending ambiguous video frames
whose camera geometry and capture time are unknown.

## Capture policy

Mapping captures at most 120 real rear-wide frames. A frame is eligible only when:

* ARKit camera tracking is normal;
* ARKit exposes at least 250 current raw feature points;
* at least 0.75 seconds have elapsed since the last accepted frame; and
* the phone has moved at least 0.45 m or rotated at least 25 degrees.

The policy is intentionally bounded and metric. Failed JPEG encoding rolls back
the reservation, so it cannot suppress the next valid keyframe. These defaults
are starting values—not accuracy-optimal universal thresholds—and must be tuned
from physical-house reports.

## Package contract

Every accepted keyframe stores:

* stable keyframe UUID and monotonically increasing mapping frame ID;
* the original `ARFrame.timestamp`;
* encoded image size/orientation (`right`, native landscape sensor pixels) and
  rear-wide camera identity;
* camera intrinsics scaled from the captured image resolution to the 1,280-pixel
  JPEG width;
* exact column-major `T_map_camera` from the same ARFrame;
* normal tracking state and source ARKit feature count;
* the actual JPEG named `<keyframe UUID>.jpg`.

`keyframes/manifest.json` is schema-versioned and map-ID bound. Save stages all
images and the manifest alongside the ARWorldMap and app-owned spatial map before
one directory move commits the package. Reload rejects duplicate keyframe/frame
IDs, invalid calibration/poses, wrong filenames, missing/extra/empty images, or
symlinks. The map menu can share the full package for desktop reconstruction.

## Coordinate and image convention

The JPEG is not portrait-rotated. Its pixel array keeps the rear sensor's native
landscape orientation and the manifest labels it `right`, matching the existing
frame-observation contract. Intrinsics therefore describe those encoded landscape
pixels directly. A server must apply the declared orientation when presenting or
transforming an image; it must not silently transpose pixels while retaining the
original calibration matrix.

## Remaining connected-localization work

This slice supplies calibrated mapping observations but does not yet run COLMAP,
HLoc, LightGlue, PnP, or depth verification. The next server slice must:

1. validate the package and import JPEGs with their known intrinsics/poses;
2. construct a versioned sparse 3D descriptor map aligned to HouseMapper's metric
   map frame;
3. accept timestamped query observations using the existing envelope contract;
4. return verified `T_map_camera`, match/inlier diagnostics, and map version;
5. bridge the accepted pose to live ARKit tracking through `T_map_world`.
