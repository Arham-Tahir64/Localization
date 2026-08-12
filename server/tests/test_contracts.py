from __future__ import annotations

import base64
import json
from pathlib import Path
from uuid import UUID

import cv2
import numpy as np
import pytest

from housemapper_server.contracts import MappingPackage, QueryObservation
from housemapper_server.errors import ContractError, PackageError


MAP_ID = UUID("11111111-2222-3333-4444-555555555555")


def column_major(matrix: np.ndarray) -> list[float]:
    return [float(value) for value in matrix.reshape(-1, order="F")]


def jpeg(width: int = 640, height: int = 480) -> bytes:
    image = np.zeros((height, width, 3), dtype=np.uint8)
    for y in range(20, height, 40):
        for x in range(20, width, 40):
            cv2.circle(image, (x, y), 6, ((x * 7) % 255, (y * 5) % 255, 220), -1)
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 90])
    assert ok
    return encoded.tobytes()


def create_package(root: Path) -> Path:
    package = root / str(MAP_ID).upper()
    keyframes = package / "keyframes"
    keyframes.mkdir(parents=True)
    (package / "metadata.json").write_text(json.dumps({
        "schemaVersion": 1,
        "id": str(MAP_ID),
        "name": "Synthetic House",
    }))
    (package / "worldmap.arexperience").write_bytes(b"opaque-world-map")
    (package / "spatial-map.plist").write_bytes(b"opaque-spatial-map")
    records = []
    for index in range(2):
        keyframe_id = UUID(f"00000000-0000-0000-0000-{index + 1:012d}")
        filename = f"{str(keyframe_id).upper()}.jpg"
        (keyframes / filename).write_bytes(jpeg())
        pose = np.eye(4)
        pose[0, 3] = index * 0.6
        records.append({
            "id": str(keyframe_id).upper(),
            "frameID": index + 1,
            "capturedAt": 1.0 + index,
            "image": {"width": 640, "height": 480, "orientation": "right", "camera": "rearWide"},
            "intrinsics": {"values": column_major(np.array([[500, 0, 320], [0, 500, 240], [0, 0, 1]], dtype=float))},
            "mapFromCamera": {"values": column_major(pose)},
            "tracking": "normal",
            "sourceFeatureCount": 900,
            "imageFileName": filename,
        })
    (keyframes / "manifest.json").write_text(json.dumps({
        "schemaVersion": 1, "mapID": str(MAP_ID).upper(), "keyframes": records,
    }))
    return package


def request_json(image: bytes | None = None) -> dict:
    encoded = image or jpeg()
    return {
        "schemaVersion": 1,
        "observation": {
            "schemaVersion": 1,
            "map": {"mapID": str(MAP_ID), "versionID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},
            "sessionID": "00000000-0000-0000-0000-000000000001",
            "frameID": 9,
            "capturedAt": 123.5,
            "image": {"width": 640, "height": 480, "orientation": "right", "camera": "rearWide"},
            "intrinsics": {"values": column_major(np.array([[500, 0, 320], [0, 500, 240], [0, 0, 1]], dtype=float))},
            "worldFromCamera": {"values": column_major(np.eye(4))},
            "tracking": "normal",
            "depth": None,
        },
        "jpegImage": base64.b64encode(encoded).decode(),
    }


def test_package_loader_preserves_exact_calibrated_records(tmp_path: Path) -> None:
    package = MappingPackage.load(create_package(tmp_path))

    assert package.map_id == MAP_ID
    assert package.name == "Synthetic House"
    assert len(package.keyframes) == 2
    assert package.keyframes[1].map_from_camera[0, 3] == pytest.approx(0.6)
    assert package.keyframes[0].intrinsics[0, 2] == pytest.approx(320)


def test_package_loader_rejects_extra_jpeg(tmp_path: Path) -> None:
    root = create_package(tmp_path)
    (root / "keyframes" / "99999999-9999-9999-9999-999999999999.jpg").write_bytes(jpeg())

    with pytest.raises(PackageError, match="exactly match"):
        MappingPackage.load(root)


def test_package_loader_rejects_symlinked_keyframe(tmp_path: Path) -> None:
    root = create_package(tmp_path)
    manifest = json.loads((root / "keyframes" / "manifest.json").read_text())
    name = manifest["keyframes"][0]["imageFileName"]
    target = root / "keyframes" / name
    outside = tmp_path / "outside.jpg"
    outside.write_bytes(target.read_bytes())
    target.unlink()
    target.symlink_to(outside)

    with pytest.raises(PackageError, match="unsafe"):
        MappingPackage.load(root)


def test_query_parser_joins_exact_jpeg_geometry_and_calibration() -> None:
    query = QueryObservation.parse(request_json())

    assert query.frame_id == 9
    assert query.geometry.width == 640
    assert query.decode_image().shape == (480, 640, 3)
    assert query.intrinsics[1, 2] == pytest.approx(240)


def test_query_parser_rejects_dimension_mismatch() -> None:
    request = request_json(jpeg(width=320, height=240))

    with pytest.raises(ContractError, match="dimensions disagree"):
        QueryObservation.parse(request)
