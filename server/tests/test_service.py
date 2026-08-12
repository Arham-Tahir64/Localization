from __future__ import annotations

from dataclasses import dataclass
import json
from uuid import UUID

import base64
import cv2
import numpy as np
from fastapi.testclient import TestClient

from housemapper_server.contracts import MapReference
from housemapper_server.errors import LocalizationError
from housemapper_server.localizer import LocalizationMetrics, LocalizationOutput
from housemapper_server.service import MAXIMUM_REQUEST_BYTES, create_app
from housemapper_server.traces import LocalizationTraceStore


@dataclass
class StubMap:
    reference: MapReference
    model_identity: dict[str, str]
    landmark_ids: np.ndarray


class StubLocalizer:
    def __init__(self) -> None:
        self.server_map = StubMap(
            MapReference(
                UUID("11111111-2222-3333-4444-555555555555"),
                UUID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            ),
            {"localFeatures": "test", "matcher": "test"},
            np.arange(80),
        )

    def localize(self, observation):
        raise LocalizationError(
            "not enough verified geometry",
            stage="correspondence",
            diagnostics={"extractedKeypoints": 41, "uniqueCorrespondences": 9},
        )


def valid_request_body() -> dict:
    image = np.zeros((48, 64, 3), dtype=np.uint8)
    ok, jpeg = cv2.imencode(".jpg", image)
    assert ok
    reference = MapReference(
        UUID("11111111-2222-3333-4444-555555555555"),
        UUID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
    )
    intrinsics = np.array([[50, 0, 32], [0, 50, 24], [0, 0, 1]], dtype=float)
    identity = np.eye(4)
    return {
        "schemaVersion": 1,
        "observation": {
            "schemaVersion": 1,
            "map": reference.json(),
            "sessionID": "00000000-0000-0000-0000-000000000001",
            "frameID": 7,
            "capturedAt": 10.5,
            "image": {"width": 64, "height": 48, "orientation": "right", "camera": "rearWide"},
            "intrinsics": {"values": intrinsics.reshape(-1, order="F").tolist()},
            "worldFromCamera": {"values": identity.reshape(-1, order="F").tolist()},
            "tracking": "normal",
            "depth": None,
        },
        "jpegImage": base64.b64encode(jpeg.tobytes()).decode(),
    }


def test_health_binds_exact_immutable_map() -> None:
    client = TestClient(create_app(StubLocalizer()))

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["map"]["versionID"] == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    assert response.json()["landmarks"] == 80


def test_localize_rejects_non_json_before_body_processing() -> None:
    client = TestClient(create_app(StubLocalizer()))

    response = client.post("/localize", content=b"not json", headers={"content-type": "text/plain"})

    assert response.status_code == 415


def test_localize_rejects_oversized_declared_body() -> None:
    client = TestClient(create_app(StubLocalizer()))

    response = client.post(
        "/localize",
        content=b"{}",
        headers={"content-type": "application/json", "content-length": str(MAXIMUM_REQUEST_BYTES + 1)},
    )

    assert response.status_code == 413


def test_localize_reports_malformed_json_as_client_error() -> None:
    client = TestClient(create_app(StubLocalizer()))

    response = client.post("/localize", content=b"{", headers={"content-type": "application/json"})

    assert response.status_code == 400


def test_localize_reports_stage_and_records_opt_in_rejection_trace(tmp_path) -> None:
    client = TestClient(create_app(StubLocalizer(), LocalizationTraceStore(tmp_path)))
    response = client.post("/localize", json=valid_request_body())

    assert response.status_code == 422
    assert response.json()["stage"] == "correspondence"
    assert response.json()["diagnostics"]["uniqueCorrespondences"] == 9
    records = list(LocalizationTraceStore(tmp_path).records())
    assert len(records) == 1
    assert records[0].metadata["outcome"] == "rejected"
    assert records[0].metadata["stage"] == "correspondence"
    health = client.get("/health").json()
    assert health["tracing"]["enabled"] is True
