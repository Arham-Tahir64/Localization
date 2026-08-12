from __future__ import annotations

from pathlib import Path
from uuid import UUID

import numpy as np
import pytest

from housemapper_server.contracts import MapReference
from housemapper_server.errors import ContractError, PackageError
from housemapper_server.map_store import ServerMap, load_server_map, write_server_map


def sample_map() -> ServerMap:
    keyframes = (
        UUID("00000000-0000-0000-0000-000000000001"),
        UUID("00000000-0000-0000-0000-000000000002"),
    )
    landmark_ids = np.arange(1, 9, dtype=np.int64)
    return ServerMap(
        MapReference(UUID("11111111-2222-3333-4444-555555555555"), UUID("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
        {"reconstruction": "metric-v1", "retrieval": "VLAD", "localFeatures": "test", "matcher": "test"},
        keyframes,
        np.array([[640, 480], [640, 480]], dtype=np.int32),
        np.array([0, 8, 16], dtype=np.int64),
        np.tile(np.arange(8, dtype=np.float32)[:, None], (2, 2)),
        np.tile(np.eye(8, dtype=np.float32), (2, 2)),
        np.tile(landmark_ids, 2),
        np.ones((2, 64), dtype=np.float32),
        np.ones((4, 16), dtype=np.float32),
        landmark_ids,
        np.column_stack((np.arange(8), np.zeros(8), -np.arange(8) - 2)).astype(np.float32),
        np.eye(8, 16, dtype=np.float32),
        np.full(8, 2, dtype=np.int16),
    )


def test_immutable_map_roundtrip_and_checksum(tmp_path: Path) -> None:
    source = sample_map()
    directory = write_server_map(tmp_path, source, query_endpoint="http://mapping-mac.local:8080/localize", map_name="House")
    loaded = load_server_map(directory)

    assert loaded.reference == source.reference
    np.testing.assert_array_equal(loaded.landmark_positions, source.landmark_positions)
    assert (directory / "server-map.json").is_file()


def test_map_checksum_rejects_modified_arrays(tmp_path: Path) -> None:
    directory = write_server_map(tmp_path, sample_map(), query_endpoint="http://mapping-mac.local:8080/localize", map_name="House")
    with (directory / "map.npz").open("ab") as stream:
        stream.write(b"tamper")

    with pytest.raises(PackageError, match="checksum"):
        load_server_map(directory)


def test_manifest_rejects_insecure_or_malformed_endpoint(tmp_path: Path) -> None:
    with pytest.raises(ContractError, match="HTTPS or Bonjour"):
        write_server_map(
            tmp_path,
            sample_map(),
            query_endpoint="http://192.168.1.4:8080/localize",
            map_name="House",
        )
