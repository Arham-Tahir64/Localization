from __future__ import annotations

import base64
from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Any
from urllib.parse import urlsplit
from uuid import UUID

import cv2
import numpy as np

from .errors import ContractError, PackageError
from .geometry import matrix_from_column_major, validate_intrinsics, validate_rigid_transform


PACKAGE_MANIFEST_SCHEMA = 1
REQUEST_SCHEMA = 1
RESPONSE_SCHEMA = 1
MAP_SCHEMA = 1
FRAME_CONVENTION = "T_map_camera-right-handed-y-up-meters"
MAXIMUM_KEYFRAMES = 120
MAXIMUM_JSON_BYTES = 2 * 1024 * 1024
MAXIMUM_JPEG_BYTES = 12 * 1024 * 1024
UUID_JPEG = re.compile(r"^[0-9A-Fa-f-]{36}\.jpg$")


def _object(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{name} must be a JSON object")
    return value


def _integer(value: Any, name: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ContractError(f"{name} must be an integer >= {minimum}")
    return value


def _finite(value: Any, name: str, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError(f"{name} must be numeric")
    number = float(value)
    if not np.isfinite(number) or (minimum is not None and number < minimum):
        raise ContractError(f"{name} must be finite and >= {minimum}")
    return number


def _uuid(value: Any, name: str) -> UUID:
    try:
        return UUID(str(value))
    except (ValueError, TypeError, AttributeError) as error:
        raise ContractError(f"{name} must be a UUID") from error


def _read_json(path: Path, maximum_bytes: int = MAXIMUM_JSON_BYTES) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise PackageError(f"missing or unsafe file: {path.name}")
    data = path.read_bytes()
    if not data or len(data) > maximum_bytes:
        raise PackageError(f"invalid JSON size for {path.name}")
    try:
        return _object(json.loads(data), path.name)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PackageError(f"invalid JSON in {path.name}") from error


def validate_query_endpoint(value: str) -> None:
    try:
        endpoint = urlsplit(value)
        port = endpoint.port
    except ValueError as error:
        raise ContractError("query endpoint is invalid") from error
    if (
        endpoint.username is not None
        or endpoint.password is not None
        or endpoint.query
        or endpoint.fragment
        or not endpoint.hostname
        or endpoint.path != "/localize"
        or (port is not None and not (1 <= port <= 65535))
    ):
        raise ContractError("query endpoint must be one credential-free /localize URL")
    host = endpoint.hostname.lower()
    if endpoint.scheme != "https" and not (
        endpoint.scheme == "http" and host.endswith(".local")
    ):
        raise ContractError("query endpoint must use HTTPS or Bonjour .local HTTP")


@dataclass(frozen=True)
class ImageGeometry:
    width: int
    height: int
    orientation: str
    camera: str

    @classmethod
    def parse(cls, value: Any) -> "ImageGeometry":
        obj = _object(value, "image")
        geometry = cls(
            width=_integer(obj.get("width"), "image.width", 1),
            height=_integer(obj.get("height"), "image.height", 1),
            orientation=str(obj.get("orientation", "")),
            camera=str(obj.get("camera", "")),
        )
        if geometry.width > 4_096 or geometry.height > 4_096:
            raise ContractError("encoded image dimensions exceed schema-v1 bounds")
        if geometry.orientation != "right" or geometry.camera != "rearWide":
            raise ContractError("schema v1 requires native-landscape rear-wide images")
        return geometry


@dataclass(frozen=True)
class MapReference:
    map_id: UUID
    version_id: UUID

    @classmethod
    def parse(cls, value: Any) -> "MapReference":
        obj = _object(value, "map")
        return cls(_uuid(obj.get("mapID"), "map.mapID"), _uuid(obj.get("versionID"), "map.versionID"))

    def json(self) -> dict[str, str]:
        return {"mapID": str(self.map_id).upper(), "versionID": str(self.version_id).upper()}


@dataclass(frozen=True)
class Keyframe:
    keyframe_id: UUID
    frame_id: int
    captured_at: float
    geometry: ImageGeometry
    intrinsics: np.ndarray
    map_from_camera: np.ndarray
    source_feature_count: int
    image_path: Path


@dataclass(frozen=True)
class MappingPackage:
    root: Path
    map_id: UUID
    name: str
    keyframes: tuple[Keyframe, ...]

    @classmethod
    def load(cls, root: Path) -> "MappingPackage":
        package_root = root.expanduser().resolve(strict=True)
        if root.is_symlink() or not package_root.is_dir():
            raise PackageError("map package must be a real directory")
        metadata = _read_json(package_root / "metadata.json")
        if _integer(metadata.get("schemaVersion"), "metadata.schemaVersion") != 1:
            raise PackageError("unsupported map metadata schema")
        map_id = _uuid(metadata.get("id"), "metadata.id")
        if package_root.name.lower() != str(map_id).lower():
            raise PackageError("map package directory name does not match metadata ID")
        name = str(metadata.get("name", "")).strip()
        if not name or len(name) > 200:
            raise PackageError("metadata.name is missing or too long")
        for required_name in ("worldmap.arexperience", "spatial-map.plist"):
            required = package_root / required_name
            if (
                required.is_symlink()
                or not required.is_file()
                or required.stat().st_size <= 0
            ):
                raise PackageError(
                    f"saved HouseMapper package is missing safe {required_name}"
                )

        keyframes_root = package_root / "keyframes"
        if keyframes_root.is_symlink() or not keyframes_root.is_dir():
            raise PackageError("keyframes directory is missing or unsafe")
        manifest = _read_json(keyframes_root / "manifest.json")
        if _integer(manifest.get("schemaVersion"), "keyframe schema") != PACKAGE_MANIFEST_SCHEMA:
            raise PackageError("unsupported keyframe manifest schema")
        if _uuid(manifest.get("mapID"), "keyframe mapID") != map_id:
            raise PackageError("keyframe manifest belongs to another map")
        records = manifest.get("keyframes")
        if not isinstance(records, list) or not (2 <= len(records) <= MAXIMUM_KEYFRAMES):
            raise PackageError(f"a server map requires 2...{MAXIMUM_KEYFRAMES} calibrated keyframes")

        parsed: list[Keyframe] = []
        keyframe_ids: set[UUID] = set()
        frame_ids: set[int] = set()
        expected_images: set[str] = set()
        for record_value in records:
            record = _object(record_value, "keyframe")
            keyframe_id = _uuid(record.get("id"), "keyframe.id")
            frame_id = _integer(record.get("frameID"), "keyframe.frameID")
            if keyframe_id in keyframe_ids or frame_id in frame_ids:
                raise PackageError("duplicate keyframe or frame identifier")
            keyframe_ids.add(keyframe_id)
            frame_ids.add(frame_id)
            file_name = str(record.get("imageFileName", ""))
            if file_name != f"{str(keyframe_id).upper()}.jpg" and file_name != f"{str(keyframe_id).lower()}.jpg":
                raise PackageError("keyframe filename does not match its UUID")
            if not UUID_JPEG.fullmatch(file_name):
                raise PackageError("unsafe keyframe filename")
            expected_images.add(file_name)
            image_path = keyframes_root / file_name
            if image_path.is_symlink() or not image_path.is_file():
                raise PackageError(f"keyframe image is missing or unsafe: {file_name}")
            size = image_path.stat().st_size
            if not (4 <= size <= MAXIMUM_JPEG_BYTES):
                raise PackageError(f"keyframe image has invalid size: {file_name}")
            encoded = np.frombuffer(image_path.read_bytes(), dtype=np.uint8)
            image = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
            geometry = ImageGeometry.parse(record.get("image"))
            if image is None or image.shape[:2] != (geometry.height, geometry.width):
                raise PackageError(f"decoded dimensions disagree with calibration: {file_name}")

            intrinsics_obj = _object(record.get("intrinsics"), "intrinsics")
            pose_obj = _object(record.get("mapFromCamera"), "mapFromCamera")
            intrinsics = matrix_from_column_major(intrinsics_obj.get("values", []), 3)
            map_from_camera = matrix_from_column_major(pose_obj.get("values", []), 4)
            validate_intrinsics(intrinsics, geometry.width, geometry.height)
            validate_rigid_transform(map_from_camera)
            if record.get("tracking") != "normal":
                raise PackageError("server-map keyframe was not captured with normal tracking")
            parsed.append(
                Keyframe(
                    keyframe_id,
                    frame_id,
                    _finite(record.get("capturedAt"), "keyframe.capturedAt", 0),
                    geometry,
                    intrinsics,
                    map_from_camera,
                    _integer(record.get("sourceFeatureCount"), "sourceFeatureCount"),
                    image_path,
                )
            )

        actual_images = {
            item.name for item in keyframes_root.iterdir()
            if item.is_file() and item.suffix.lower() == ".jpg"
        }
        if actual_images != expected_images:
            raise PackageError("keyframe image set does not exactly match manifest")
        parsed.sort(key=lambda item: (item.captured_at, item.frame_id))
        return cls(package_root, map_id, name, tuple(parsed))


@dataclass(frozen=True)
class QueryObservation:
    map: MapReference
    session_id: UUID
    frame_id: int
    captured_at: float
    geometry: ImageGeometry
    intrinsics: np.ndarray
    world_from_camera: np.ndarray
    jpeg_image: bytes

    @classmethod
    def parse(cls, value: Any) -> "QueryObservation":
        request = _object(value, "request")
        if _integer(request.get("schemaVersion"), "request.schemaVersion") != REQUEST_SCHEMA:
            raise ContractError("unsupported localization request schema")
        observation = _object(request.get("observation"), "observation")
        if _integer(observation.get("schemaVersion"), "observation.schemaVersion") != REQUEST_SCHEMA:
            raise ContractError("unsupported observation schema")
        if observation.get("depth") is not None or observation.get("tracking") != "normal":
            raise ContractError("schema v1 accepts normal-tracking RGB observations without depth")
        geometry = ImageGeometry.parse(observation.get("image"))
        intrinsics = matrix_from_column_major(_object(observation.get("intrinsics"), "intrinsics").get("values", []), 3)
        world_from_camera = matrix_from_column_major(_object(observation.get("worldFromCamera"), "worldFromCamera").get("values", []), 4)
        validate_intrinsics(intrinsics, geometry.width, geometry.height)
        validate_rigid_transform(world_from_camera)
        encoded = request.get("jpegImage")
        if not isinstance(encoded, str):
            raise ContractError("jpegImage must be Base64 text")
        try:
            jpeg = base64.b64decode(encoded, validate=True)
        except ValueError as error:
            raise ContractError("jpegImage is invalid Base64") from error
        if not (4 <= len(jpeg) <= MAXIMUM_JPEG_BYTES) or jpeg[:2] != b"\xff\xd8" or jpeg[-2:] != b"\xff\xd9":
            raise ContractError("jpegImage is not a bounded JPEG")
        image = cv2.imdecode(np.frombuffer(jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None or image.shape[:2] != (geometry.height, geometry.width):
            raise ContractError("query JPEG dimensions disagree with observation")
        return cls(
            MapReference.parse(observation.get("map")),
            _uuid(observation.get("sessionID"), "sessionID"),
            _integer(observation.get("frameID"), "frameID"),
            _finite(observation.get("capturedAt"), "capturedAt", 0),
            geometry,
            intrinsics,
            world_from_camera,
            jpeg,
        )

    def decode_image(self) -> np.ndarray:
        image = cv2.imdecode(np.frombuffer(self.jpeg_image, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise ContractError("query JPEG can no longer be decoded")
        return image
