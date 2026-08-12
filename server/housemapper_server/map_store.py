from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from typing import Any
from uuid import UUID, uuid4
import zipfile

import numpy as np

from .contracts import FRAME_CONVENTION, MAP_SCHEMA, MapReference, validate_query_endpoint
from .errors import ContractError, PackageError


MAXIMUM_MAP_BYTES = 768 * 1024 * 1024
MAXIMUM_UNCOMPRESSED_ARRAY_BYTES = 1_024 * 1024 * 1024
MAXIMUM_KEYFRAMES = 120
MAXIMUM_KEYPOINTS = MAXIMUM_KEYFRAMES * 4_096
MAXIMUM_LANDMARKS = 300_000


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class ServerMap:
    reference: MapReference
    model_identity: dict[str, str]
    keyframe_ids: tuple[UUID, ...]
    keyframe_image_sizes: np.ndarray
    keyframe_keypoint_offsets: np.ndarray
    keypoints: np.ndarray
    descriptors: np.ndarray
    keypoint_landmark_ids: np.ndarray
    retrieval_descriptors: np.ndarray
    vlad_centers: np.ndarray
    landmark_ids: np.ndarray
    landmark_positions: np.ndarray
    landmark_descriptors: np.ndarray
    landmark_track_lengths: np.ndarray

    def validate(self) -> None:
        keyframe_count = len(self.keyframe_ids)
        if (
            not (2 <= keyframe_count <= MAXIMUM_KEYFRAMES)
            or len(set(self.keyframe_ids)) != keyframe_count
            or self.keyframe_image_sizes.shape != (keyframe_count, 2)
        ):
            raise ContractError("server map keyframe table is invalid")
        if self.keyframe_keypoint_offsets.shape != (keyframe_count + 1,):
            raise ContractError("server map keypoint offsets are invalid")
        if self.keyframe_keypoint_offsets[0] != 0 or np.any(np.diff(self.keyframe_keypoint_offsets) < 0):
            raise ContractError("server map keypoint offsets are non-monotonic")
        keypoint_count = int(self.keyframe_keypoint_offsets[-1])
        descriptor_dimension = self.descriptors.shape[1] if self.descriptors.ndim == 2 else 0
        if (
            self.keypoints.shape != (keypoint_count, 2)
            or self.descriptors.shape[0] != keypoint_count
            or self.keypoint_landmark_ids.shape != (keypoint_count,)
            or not (16 <= descriptor_dimension <= 512)
            or keypoint_count > MAXIMUM_KEYPOINTS
        ):
            raise ContractError("server map keypoint/descriptor arrays disagree")
        if (
            self.vlad_centers.ndim != 2
            or self.vlad_centers.shape[1] != descriptor_dimension
            or self.retrieval_descriptors.shape
            != (keyframe_count, self.vlad_centers.shape[0] * descriptor_dimension)
        ):
            raise ContractError("server map retrieval table is invalid")
        landmark_count = len(self.landmark_ids)
        if (
            not (6 <= landmark_count <= MAXIMUM_LANDMARKS)
            or len(np.unique(self.landmark_ids)) != landmark_count
            or np.any(np.diff(self.landmark_ids) <= 0)
        ):
            raise ContractError("server map landmark identifiers are invalid")
        if (
            self.landmark_positions.shape != (landmark_count, 3)
            or self.landmark_descriptors.shape != (landmark_count, descriptor_dimension)
            or self.landmark_track_lengths.shape != (landmark_count,)
            or np.any(self.landmark_track_lengths < 2)
        ):
            raise ContractError("server map landmark arrays disagree")
        if not all(
            np.all(np.isfinite(array))
            for array in (
                self.keypoints,
                self.descriptors,
                self.retrieval_descriptors,
                self.vlad_centers,
                self.landmark_positions,
                self.landmark_descriptors,
            )
        ):
            raise ContractError("server map contains non-finite values")
        known = set(int(value) for value in self.landmark_ids)
        if any(int(value) != -1 and int(value) not in known for value in self.keypoint_landmark_ids):
            raise ContractError("keypoint references an unknown map landmark")
        required_models = {"reconstruction", "retrieval", "localFeatures", "matcher"}
        if set(self.model_identity) != required_models or any(
            not isinstance(value, str) or not value.strip() or len(value) > 120
            for value in self.model_identity.values()
        ):
            raise ContractError("server map model identity is incomplete or invalid")
        expected_dtypes = {
            "keyframe_image_sizes": (self.keyframe_image_sizes.dtype, np.integer),
            "keyframe_keypoint_offsets": (self.keyframe_keypoint_offsets.dtype, np.integer),
            "keypoints": (self.keypoints.dtype, np.floating),
            "descriptors": (self.descriptors.dtype, np.floating),
            "keypoint_landmark_ids": (self.keypoint_landmark_ids.dtype, np.integer),
            "retrieval_descriptors": (self.retrieval_descriptors.dtype, np.floating),
            "vlad_centers": (self.vlad_centers.dtype, np.floating),
            "landmark_ids": (self.landmark_ids.dtype, np.integer),
            "landmark_positions": (self.landmark_positions.dtype, np.floating),
            "landmark_descriptors": (self.landmark_descriptors.dtype, np.floating),
            "landmark_track_lengths": (self.landmark_track_lengths.dtype, np.integer),
        }
        if any(not np.issubdtype(dtype, family) for dtype, family in expected_dtypes.values()):
            raise ContractError("server map array dtype is incompatible")

    def keyframe_features(self, index: int):
        from .features import ImageFeatures

        start = int(self.keyframe_keypoint_offsets[index])
        end = int(self.keyframe_keypoint_offsets[index + 1])
        descriptor = self.descriptors[start:end]
        mean = descriptor.mean(axis=0)
        mean /= max(float(np.linalg.norm(mean)), 1e-12)
        width, height = self.keyframe_image_sizes[index]
        return ImageFeatures(
            self.keypoints[start:end],
            descriptor,
            np.ones(end - start, dtype=np.float32),
            mean.astype(np.float32),
            (int(width), int(height)),
        )

    def keyframe_landmark_ids(self, index: int) -> np.ndarray:
        start = int(self.keyframe_keypoint_offsets[index])
        end = int(self.keyframe_keypoint_offsets[index + 1])
        return self.keypoint_landmark_ids[start:end]

    def landmark_positions_for_ids(self, identifiers: np.ndarray) -> np.ndarray:
        indices = np.searchsorted(self.landmark_ids, identifiers)
        if np.any(indices >= len(self.landmark_ids)) or np.any(self.landmark_ids[indices] != identifiers):
            raise ContractError("localization referenced an unknown landmark")
        return self.landmark_positions[indices]


def write_server_map(
    destination_root: Path,
    server_map: ServerMap,
    *,
    query_endpoint: str,
    map_name: str,
) -> Path:
    server_map.validate()
    validate_query_endpoint(query_endpoint)
    root = destination_root.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    final = root / f"{server_map.reference.map_id}-{server_map.reference.version_id}"
    if final.exists():
        raise PackageError(f"immutable server map already exists: {final}")
    staging = Path(tempfile.mkdtemp(prefix=".housemapper-map-", dir=root))
    try:
        arrays_path = staging / "map.npz"
        np.savez_compressed(
            arrays_path,
            keyframe_image_sizes=server_map.keyframe_image_sizes,
            keyframe_keypoint_offsets=server_map.keyframe_keypoint_offsets,
            keypoints=server_map.keypoints,
            descriptors=server_map.descriptors,
            keypoint_landmark_ids=server_map.keypoint_landmark_ids,
            retrieval_descriptors=server_map.retrieval_descriptors,
            vlad_centers=server_map.vlad_centers,
            landmark_ids=server_map.landmark_ids,
            landmark_positions=server_map.landmark_positions,
            landmark_descriptors=server_map.landmark_descriptors,
            landmark_track_lengths=server_map.landmark_track_lengths,
        )
        digest = _sha256_file(arrays_path)
        metadata = {
            "schemaVersion": MAP_SCHEMA,
            "map": server_map.reference.json(),
            "name": map_name,
            "frameConvention": FRAME_CONVENTION,
            "keyframeIDs": [str(value).upper() for value in server_map.keyframe_ids],
            "models": server_map.model_identity,
            "arraysSHA256": digest,
            "counts": {
                "keyframes": len(server_map.keyframe_ids),
                "keypoints": len(server_map.keypoints),
                "landmarks": len(server_map.landmark_ids),
            },
        }
        (staging / "map.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
        manifest = {
            "schemaVersion": 1,
            "map": server_map.reference.json(),
            "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "queryEndpoint": query_endpoint,
            "frameConvention": FRAME_CONVENTION,
            "models": server_map.model_identity,
            "query": {
                "maximumImageWidth": 1280,
                "jpegQuality": 0.8,
                "minimumQueryInterval": 0.75,
                "requestTimeout": 8,
            },
        }
        (staging / "server-map.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        os.replace(staging, final)
        return final
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def load_server_map(directory: Path) -> ServerMap:
    root = directory.expanduser().resolve(strict=True)
    if directory.is_symlink() or not root.is_dir():
        raise PackageError("server map must be a real directory")
    metadata_path = root / "map.json"
    arrays_path = root / "map.npz"
    if metadata_path.is_symlink() or arrays_path.is_symlink() or not metadata_path.is_file() or not arrays_path.is_file():
        raise PackageError("server map files are missing or unsafe")
    if metadata_path.stat().st_size > 2 * 1024 * 1024 or arrays_path.stat().st_size > MAXIMUM_MAP_BYTES:
        raise PackageError("server map exceeds configured bounds")
    metadata = json.loads(metadata_path.read_text())
    if metadata.get("schemaVersion") != MAP_SCHEMA or metadata.get("frameConvention") != FRAME_CONVENTION:
        raise PackageError("server map schema or frame convention is incompatible")
    if _sha256_file(arrays_path) != metadata.get("arraysSHA256"):
        raise PackageError("server map checksum does not match")
    try:
        with zipfile.ZipFile(arrays_path) as archive_info:
            members = archive_info.infolist()
            if (
                len(members) != 11
                or any(member.is_dir() or not member.filename.endswith(".npy") for member in members)
                or sum(member.file_size for member in members) > MAXIMUM_UNCOMPRESSED_ARRAY_BYTES
            ):
                raise PackageError("server map compressed arrays exceed configured bounds")
    except zipfile.BadZipFile as error:
        raise PackageError("server map array archive is invalid") from error
    reference = MapReference.parse(metadata.get("map"))
    keyframe_ids = tuple(UUID(value) for value in metadata.get("keyframeIDs", []))
    with np.load(arrays_path, allow_pickle=False) as archive:
        required = {
            "keyframe_image_sizes", "keyframe_keypoint_offsets", "keypoints", "descriptors",
            "keypoint_landmark_ids", "retrieval_descriptors", "vlad_centers", "landmark_ids",
            "landmark_positions", "landmark_descriptors", "landmark_track_lengths",
        }
        if set(archive.files) != required:
            raise PackageError("server map array set is incomplete or unexpected")
        loaded = ServerMap(
            reference,
            dict(metadata.get("models", {})),
            keyframe_ids,
            archive["keyframe_image_sizes"],
            archive["keyframe_keypoint_offsets"],
            archive["keypoints"],
            archive["descriptors"],
            archive["keypoint_landmark_ids"],
            archive["retrieval_descriptors"],
            archive["vlad_centers"],
            archive["landmark_ids"],
            archive["landmark_positions"],
            archive["landmark_descriptors"],
            archive["landmark_track_lengths"],
        )
    loaded.validate()
    counts = metadata.get("counts")
    if counts != {
        "keyframes": len(loaded.keyframe_ids),
        "keypoints": len(loaded.keypoints),
        "landmarks": len(loaded.landmark_ids),
    }:
        raise PackageError("server map declared counts do not match its arrays")
    return loaded


def new_map_reference(map_id: UUID) -> MapReference:
    return MapReference(map_id, uuid4())
