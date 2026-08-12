# Learned server localization benchmark

Date: 2026-08-11

## Scope

This is the mandatory host performance benchmark for the implemented server. It
measures pinned ALIKED/LightGlue inference, map-trained VLAD retrieval, OpenCV PnP,
memory, and a full ten-candidate localization loop. It uses deterministic synthetic
texture/geometry so it can be reproduced without exposing home images.

It is **not** an iPhone benchmark and **not** a physical localization-accuracy
claim. The synthetic 3D test only checks coordinate/solver consistency.

## Environment

- Apple Silicon Mac, macOS 26.3.1 arm64;
- Python 3.12.13;
- PyTorch 2.13.0, MPS;
- OpenCV 5.0.0;
- NumPy 2.5.2;
- ALIKED-n16rot up to 4,096 points;
- LightGlue ALIKED accuracy mode: adaptive depth and width pruning disabled.

Reproduce from the repository root after installing `server[test]`:

```sh
TORCH_HOME=/tmp/housemapper-torch-cache PYTHONPATH=server \
  .server-venv/bin/python server/benchmarks/run_benchmarks.py \
  --device mps --iterations 10
```

## Results

| Operation | Input | Iterations | Median | p95 / max |
|---|---:|---:|---:|---:|
| ALIKED extraction | 1,280×960, 678 points | 10 | 98.81 ms | 99.89 ms |
| LightGlue pair match | 678×606 points, 535 matches | 10 | 37.50 ms | 37.85 ms |
| VLAD retrieval | 12 keyframes × 4,096 descriptors | 50 | 3.89 ms | 4.25 / 4.50 ms |
| PnP RANSAC + LM | 500 correspondences, 100 outliers | 100 | 0.539 ms | 0.673 / 0.776 ms |
| Full localization | extraction + 10 matches + PnP + response | 5 | 612.93 ms | 629.77 ms |

The complete run extracted 708 query features, produced 6,120 raw pair matches,
612 unique query↔landmark correspondences, and returned 611 verified inliers in the
synthetic repeated-view setup.

Model/process memory:

- RSS before model creation: 60,276,736 bytes;
- RSS after model creation: 482,344,960 bytes;
- model delta: 421,527,552 bytes;
- RSS after warm learned inference: 427,524,096 bytes;
- post-inference delta relative to model-load snapshot: -54,820,864 bytes (allocator
  release; this is why both absolute snapshots are reported).

Cold model construction with locally cached weights took 1.945 seconds. An earlier
complete run measured 527.70 ms median; the final post-voting run measured 612.93
ms. The variation is evidence to retain a real-device/server latency distribution,
not a reason to quote a single host value as universal.

Synthetic coordinate sanity with 20% outliers recovered:

- 400/500 PnP inliers;
- 0.458 px median residual;
- 0.000353 m translation error;
- 0.00504° rotation error.

Those tiny synthetic errors prove the projection/conversion/PnP implementation is
self-consistent. They do not predict error in a real house.

## Decisions from the benchmark

- Keep ten retrieved keyframes initially: the measured 613 ms compute fits the
  client's 750 ms minimum query interval on this Mac with useful margin.
- Keep accuracy-mode LightGlue. Adaptive pruning could reduce latency but must wait
  for a held-out recall comparison.
- Do not spend optimization effort on PnP or 12-frame retrieval; together they are
  under 5 ms median. Learned extraction and candidate matching dominate.
- Serialize inference with one server lock. Concurrent MPS requests would increase
  memory pressure and latency variance, while the iPhone already allows one query
  in flight.
- Keep the 40-inlier/0.25/3 px client gates. The performance result provides no
  evidence for weakening geometric acceptance.
- The observed 428–482 MB RSS is appropriate for a computer backend but confirms
  why this learned accuracy path was not placed inside the iPhone process.

## Next benchmark

Use a physical map and held-out query set. Report p50/p95/p99 end-to-end latency,
network time, feature count, retrieved-keyframe rank, raw/unique/inlier counts,
translation/rotation error, false accept rate, localization recall, and time to two
consistent results. Run distinct lighting, blur, room, hallway, and furniture-change
subsets before tuning retrieval count or learned-feature thresholds.
