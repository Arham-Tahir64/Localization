from __future__ import annotations

from dataclasses import dataclass
import json
from uuid import UUID

import numpy as np
from fastapi.testclient import TestClient

from housemapper_server.contracts import MapReference
from housemapper_server.errors import LocalizationError
from housemapper_server.localizer import LocalizationMetrics, LocalizationOutput
from housemapper_server.service import MAXIMUM_REQUEST_BYTES, create_app


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
        raise LocalizationError("not enough verified geometry")


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
