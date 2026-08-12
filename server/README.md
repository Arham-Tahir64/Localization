# HouseMapper connected localization server

This directory implements the computer-assisted path described in
`docs/12-connected-server-localization.md`. It consumes the **actual calibrated
keyframes exported by HouseMapper**, triangulates a metric descriptor map in the
saved ARKit map frame, and serves retrieval → local matching → PnP results to the
iPhone. It does not invent display points and it does not reconstruct a map from
the reference screenshot.

## What is implemented

- exact package validation: map/keyframe/frame IDs, calibrated image dimensions,
  intrinsics, `T_map_camera`, tracking state, filenames, file sets, and symlinks;
- ALIKED-n16rot at up to 4,096 features per frame and accuracy-mode LightGlue;
- exact LightGlue source commit and SHA-256-locked pretrained weight files;
- candidate keyframe pairs from capture order, saved metric pose proximity, and
  descriptor similarity;
- calibrated metric triangulation with parallax, cheirality, track uniqueness,
  and reprojection gates;
- map-specific VLAD place retrieval;
- unique, multi-view-voted 2D↔3D correspondences;
- AP3P RANSAC followed by LM pose refinement;
- client-compatible real 2D/3D inliers and upper-median reprojection statistic;
- immutable, checksummed, bounded server maps;
- bounded JSON HTTP service, one model inference at a time, and no redirect or
  weak-pose success path.

The SIFT backend is an explicitly named CPU baseline for debugging. It cannot open
a learned map and is not the recommended accuracy configuration.

## Requirements

- Python 3.10–3.13; Python 3.12 is the verified version;
- macOS Apple Silicon with MPS, or Linux with a CUDA GPU, strongly recommended;
- the iPhone and server on the same trusted LAN for a `.local` HTTP endpoint;
- the full HouseMapper package shared from the iPhone after a new scan.

Home images and the sparse map remain sensitive. The current LAN proof of concept
has no authentication. Use only a private trusted network, stop the server after
testing, and use HTTPS plus authentication before any internet deployment.

## Install

From the repository root:

```sh
python3.12 -m venv .server-venv
.server-venv/bin/pip install -e './server[test]'
```

The first learned-backend command downloads the official ALIKED and LightGlue
weights. HouseMapper verifies their SHA-256 digests and refuses changed weights.

## Build an immutable map

1. On iPhone, map the environment with slow motion and overlapping views. The
   mapping screen must show calibrated keyframes increasing.
2. Save the map.
3. On Home, open that map's `…` menu and choose **Share Calibrated Map Package**.
   AirDrop or save the complete UUID-named directory to the Mac.
4. Find the Mac Bonjour name in **System Settings → General → Sharing → Local
   hostname**. If it is `mapping-mac.local`, build with:

```sh
.server-venv/bin/housemapper-server validate-package /path/to/MAP-UUID
.server-venv/bin/housemapper-server build /path/to/MAP-UUID \
  --output "$PWD/server-maps" \
  --endpoint http://mapping-mac.local:8080/localize \
  --backend learned \
  --device auto
```

The builder refuses too few verified landmarks or a disconnected calibrated view
graph. Fix the scan—slower motion, more texture, more overlap, fewer skipped
hallway turns—instead of weakening the geometry gates.

The command prints an immutable map directory and the exact
`server-map.json` to attach on iPhone.

## Serve and connect the iPhone

```sh
.server-venv/bin/housemapper-server inspect /path/to/IMMUTABLE-SERVER-MAP
.server-venv/bin/housemapper-server serve /path/to/IMMUTABLE-SERVER-MAP \
  --backend learned \
  --device auto \
  --port 8080 \
  --trace-directory /private/path/to/housemapper-traces
```

`--trace-directory` is optional and stores the exact query JPEGs and calibration
for replay. It contains sensitive images of the mapped space; keep it outside the
repository, do not sync it to a public service, and delete it after evaluation.

Verify from another machine on the LAN if desired:

```sh
curl http://mapping-mac.local:8080/health
```

On the iPhone:

1. Open the saved map's `…` menu.
2. Choose **Attach Server Localization Map** and select the generated
   `server-map.json`.
3. Start relocalization. HouseMapper first tries the native ARWorldMap for 10
   seconds. If it has not restored, it starts fresh local VIO and sends bounded
   calibrated queries to the selected server map.
4. Point at a distinctive, previously scanned area and move slowly. The first
   accepted server pose remains withheld; a second consistent result confirms the
   map/world bridge. Green dots are only the server's PnP inlier landmarks,
   reprojected through the current live ARKit pose.

HTTP 422 means the current image did not produce strong enough geometry; no pose is
published. Its stage is preserved separately from network failures in Validation
History. A connection failure leaves native localization and local VIO available.

Replay the captured set after any model, map, or threshold change:

```sh
.server-venv/bin/housemapper-server replay /path/to/IMMUTABLE-SERVER-MAP \
  /private/path/to/housemapper-traces \
  --backend learned --device auto \
  --output replay-report.json
```

The command exits with status 3 if any accepted/rejected decision changes. A stable
decision is not proof of correctness; checkpoint labels remain the external source
of truth for physical pose error and false accepts.

## Test and benchmark

```sh
TORCH_HOME=/tmp/housemapper-torch-cache .server-venv/bin/pytest server/tests
TORCH_HOME=/tmp/housemapper-torch-cache PYTHONPATH=server \
  .server-venv/bin/python server/benchmarks/run_benchmarks.py \
  --device mps --iterations 10
```

See `docs/benchmarks/12-server-localization.md`. Host synthetic timing proves
runtime shape and coordinate consistency, not physical-house localization
accuracy. The next required evidence is a held-out iPhone route with surveyed or
repeatable checkpoints.
