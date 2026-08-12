from __future__ import annotations

import json
from pathlib import Path
from uuid import UUID

import numpy as np

from housemapper_server.contracts import MapReference, QueryObservation
from housemapper_server.errors import LocalizationError
from housemapper_server.errors import ContractError
from housemapper_server.traces import LocalizationTraceStore, replay_traces

from test_localizer import request


class RejectingReplayLocalizer:
    class Map:
        reference = MapReference(UUID(int=1), UUID(int=2))
        model_identity = {"localFeatures": "test", "matcher": "test"}

    server_map = Map()

    def localize(self, observation):
        raise LocalizationError(
            "not enough geometry",
            stage="correspondence",
            diagnostics={"extractedKeypoints": 32, "uniqueCorrespondences": 7},
        )


def test_trace_store_preserves_request_and_replay_decision(tmp_path: Path) -> None:
    reference = MapReference(UUID(int=1), UUID(int=2))
    observation = request(reference, np.array([[900, 0, 640], [0, 900, 480], [0, 0, 1]], dtype=float))
    body = json.dumps({
        "schemaVersion": 1,
        "observation": {
            "schemaVersion": 1,
            "map": reference.json(),
            "sessionID": str(observation.session_id),
            "frameID": observation.frame_id,
            "capturedAt": observation.captured_at,
            "image": {"width": 1280, "height": 960, "orientation": "right", "camera": "rearWide"},
            "intrinsics": {"values": observation.intrinsics.reshape(-1, order="F").tolist()},
            "worldFromCamera": {"values": observation.world_from_camera.reshape(-1, order="F").tolist()},
            "tracking": "normal",
            "depth": None,
        },
        "jpegImage": __import__("base64").b64encode(observation.jpeg_image).decode(),
    }).encode()
    parsed = QueryObservation.parse(json.loads(body))
    store = LocalizationTraceStore(tmp_path)
    store.record(
        request_body=body,
        observation=parsed,
        outcome="rejected",
        duration_seconds=0.1,
        stage="correspondence",
        diagnostics={"uniqueCorrespondences": 7},
    )

    records = list(store.records())
    assert len(records) == 1
    assert records[0].request_body == body
    report = replay_traces(RejectingReplayLocalizer(), store)
    assert report["traceCount"] == 1
    assert report["rejectedCount"] == 1
    assert report["outcomeRegressionCount"] == 0
    assert report["results"][0]["stage"] == "correspondence"


def test_replay_refuses_missing_or_empty_trace_sets(tmp_path: Path) -> None:
    missing = tmp_path / "missing"
    try:
        LocalizationTraceStore(missing, create=False)
        raise AssertionError("expected a missing replay set to be rejected")
    except ContractError:
        pass

    empty = LocalizationTraceStore(tmp_path / "empty")
    try:
        replay_traces(RejectingReplayLocalizer(), empty)
        raise AssertionError("expected an empty replay set to be rejected")
    except ContractError:
        pass
