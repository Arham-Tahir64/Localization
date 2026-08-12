from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import statistics
import tempfile
from time import perf_counter
from uuid import UUID

import cv2
import numpy as np

from housemapper_server.contracts import MapReference, QueryObservation
from housemapper_server.traces import LocalizationTraceStore


def make_request() -> tuple[bytes, QueryObservation]:
    rng = np.random.default_rng(20260811)
    image = rng.integers(0, 256, size=(960, 1280, 3), dtype=np.uint8)
    ok, jpeg = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 80])
    if not ok:
        raise RuntimeError("benchmark JPEG encoding failed")
    intrinsics = np.array([[900, 0, 640], [0, 900, 480], [0, 0, 1]], dtype=float)
    identity = np.eye(4)
    request = {
        "schemaVersion": 1,
        "observation": {
            "schemaVersion": 1,
            "map": MapReference(UUID(int=1), UUID(int=2)).json(),
            "sessionID": str(UUID(int=3)),
            "frameID": 1,
            "capturedAt": 1.0,
            "image": {"width": 1280, "height": 960, "orientation": "right", "camera": "rearWide"},
            "intrinsics": {"values": intrinsics.reshape(-1, order="F").tolist()},
            "worldFromCamera": {"values": identity.reshape(-1, order="F").tolist()},
            "tracking": "normal",
            "depth": None,
        },
        "jpegImage": base64.b64encode(jpeg.tobytes()).decode(),
    }
    body = json.dumps(request, separators=(",", ":")).encode()
    return body, QueryObservation.parse(request)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=100)
    arguments = parser.parse_args()
    body, observation = make_request()
    durations = []
    with tempfile.TemporaryDirectory(prefix="housemapper-trace-benchmark-") as directory:
        store = LocalizationTraceStore(Path(directory))
        for _ in range(arguments.iterations):
            started = perf_counter()
            store.record(
                request_body=body,
                observation=observation,
                outcome="rejected",
                duration_seconds=0.6,
                stage="correspondence",
                diagnostics={"extractedKeypoints": 900, "uniqueCorrespondences": 20},
            )
            durations.append((perf_counter() - started) * 1_000)
        ordered = sorted(durations)
        print(json.dumps({
            "kind": "host-trace-storage-overhead-not-iphone",
            "iterations": arguments.iterations,
            "requestBytes": len(body),
            "storedBytes": sum(item.stat().st_size for child in Path(directory).iterdir() for item in child.iterdir()),
            "medianMilliseconds": statistics.median(durations),
            "p95Milliseconds": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
            "maximumMilliseconds": max(durations),
        }, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
