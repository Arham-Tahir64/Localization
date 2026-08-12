# Connected localization evaluation trace benchmark

Date: 2026-08-11

## Correctness findings

The evaluation work found and corrected three measurement/recall problems:

1. The iPhone required at least 150 public ARKit sparse points before sending a
   server query. ALIKED operates on the camera image and does not depend on that
   sparse cloud, so the gate prevented the connected fallback from running in
   exactly the low-feature cases where learned image features may help. Queries
   now require normal ARKit tracking, valid calibration, and the existing rate
   limit, but not an arbitrary raw-point count.
2. HTTP 422 means a valid image was processed but failed geometric localization.
   The client previously counted it as a transport failure. It now records a
   vision rejection and preserves the server stage (`extraction`, `matching`,
   `correspondence`, `pnp`, or `verification`) in the device benchmark.
3. Mapping keyframe capture used the same wrong proxy, requiring 250 ARKit sparse
   landmarks even though the desktop map is built from ALIKED camera features.
   The capture-health floor is now 80. Normal tracking, calibrated pose novelty,
   0.75 s spacing, the 120-frame bound, learned matching, and triangulation gates
   remain mandatory; weak images are not promoted into landmarks.

The server can now opt in to storing the exact bounded request, its SHA-256,
decision, stage, counts, and stage timings. Invalid contracts are never captured.
The `replay` command re-runs those requests against an immutable map and returns a
nonzero exit code if any accepted/rejected decision changes.
It also binds every trace's map/session/frame/capture time back to the exact
request and records retrieved keyframe IDs/similarities plus map/model identity.

## Host storage benchmark

Command:

```sh
PYTHONPATH=server .server-venv/bin/python \
  server/benchmarks/benchmark_trace_store.py --iterations 100
```

Environment: Apple Silicon Mac, macOS 26.3.1, Python 3.12.13. Each JSON request
was 1,094,910 bytes and included a Base64 1,280×960 JPEG plus calibration.

| Operation | Iterations | Median | p95 | Maximum |
|---|---:|---:|---:|---:|
| Atomic trace request + metadata persistence | 100 | 1.584 ms | 2.309 ms | 2.994 ms |

The 100 records occupied 109,547,500 bytes. Trace I/O is dispatched off the
FastAPI event loop, bounded to 10,000 records / 20 GiB, and a trace write failure
does not alter the localization response. The timing is a Mac filesystem
microbenchmark, not iPhone latency and not localization accuracy.

## Physical benchmark still required

Start the server with `--trace-directory`, perform held-out house walks, then run
`housemapper-server replay`. Label repeatable checkpoints outside the captured
request so translation/rotation error, false accepts, recall, jitter, and time to
two consistent poses can be computed without treating the server's own answer as
ground truth.
