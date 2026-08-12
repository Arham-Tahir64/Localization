from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
from time import perf_counter
from typing import Any, Iterable, Protocol
from uuid import uuid4

from .contracts import QueryObservation
from .errors import ContractError, LocalizationError
from .localizer import LocalizationOutput


TRACE_SCHEMA = 1
MAXIMUM_TRACE_COUNT = 10_000
MAXIMUM_TRACE_ROOT_BYTES = 20 * 1024 * 1024 * 1024
MAXIMUM_TRACE_REQUEST_BYTES = 12 * 1024 * 1024
MAXIMUM_TRACE_METADATA_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class TraceRecord:
    directory: Path
    metadata: dict[str, Any]
    request_body: bytes


class ReplayLocalizer(Protocol):
    server_map: Any

    def localize(self, observation: QueryObservation) -> LocalizationOutput: ...


class LocalizationTraceStore:
    """Opt-in, bounded storage for sensitive replayable localization requests."""

    def __init__(self, root: Path, *, create: bool = True) -> None:
        candidate = root.expanduser()
        if candidate.is_symlink():
            raise ContractError("trace directory cannot be a symlink")
        if create:
            candidate.mkdir(parents=True, exist_ok=True)
        elif not candidate.is_dir():
            raise ContractError("replay trace directory does not exist")
        self.root = candidate.resolve(strict=True)
        if not self.root.is_dir():
            raise ContractError("trace path must be a directory")
        entries = list(self.root.iterdir())
        if any(entry.is_symlink() or not entry.is_dir() for entry in entries):
            raise ContractError("trace root contains an unsafe entry")
        if any(entry.name.startswith(".") for entry in entries):
            raise ContractError("trace root contains an incomplete staging record")
        records = [entry for entry in entries if not entry.name.startswith(".")]
        for record in records:
            children = list(record.iterdir())
            if (
                {item.name for item in children} != {"request.json", "trace.json"}
                or any(item.is_symlink() or not item.is_file() for item in children)
            ):
                raise ContractError("trace root contains an incomplete or unsafe record")
        self._record_count = len(records)
        self._byte_count = sum(
            item.stat().st_size
            for child in records
            for item in child.iterdir()
        )
        self._lock = threading.Lock()

    def record(
        self,
        *,
        request_body: bytes,
        observation: QueryObservation,
        outcome: str,
        duration_seconds: float,
        stage: str,
        diagnostics: dict[str, Any],
        detail: str | None = None,
    ) -> Path:
        if outcome not in {"accepted", "rejected"}:
            raise ContractError("trace outcome must be accepted or rejected")
        if not request_body or len(request_body) > MAXIMUM_TRACE_REQUEST_BYTES:
            raise ContractError("trace request exceeds its byte limit")
        if not duration_seconds >= 0:
            raise ContractError("trace duration must be nonnegative")
        with self._lock:
            if self._record_count >= MAXIMUM_TRACE_COUNT:
                raise ContractError("trace directory reached its record limit")
            identifier = f"{str(observation.session_id).upper()}-{observation.frame_id:020d}-{uuid4()}"
            final = self.root / identifier
            staging = Path(tempfile.mkdtemp(prefix=".trace-", dir=self.root))
            try:
                request_path = staging / "request.json"
                request_path.write_bytes(request_body)
                metadata = {
                    "schemaVersion": TRACE_SCHEMA,
                    "recordedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                    "map": observation.map.json(),
                    "sessionID": str(observation.session_id).upper(),
                    "frameID": observation.frame_id,
                    "capturedAt": observation.captured_at,
                    "outcome": outcome,
                    "stage": stage,
                    "detail": detail,
                    "durationMilliseconds": duration_seconds * 1_000,
                    "diagnostics": diagnostics,
                    "requestSHA256": hashlib.sha256(request_body).hexdigest(),
                }
                encoded_metadata = (
                    json.dumps(metadata, indent=2, sort_keys=True, allow_nan=False) + "\n"
                ).encode()
                if len(encoded_metadata) > MAXIMUM_TRACE_METADATA_BYTES:
                    raise ContractError("trace metadata exceeds its byte limit")
                (staging / "trace.json").write_bytes(encoded_metadata)
                staged_bytes = sum(item.stat().st_size for item in staging.iterdir())
                if self._byte_count + staged_bytes > MAXIMUM_TRACE_ROOT_BYTES:
                    raise ContractError("trace directory reached its byte limit")
                os.replace(staging, final)
                self._record_count += 1
                self._byte_count += staged_bytes
                return final
            except Exception:
                shutil.rmtree(staging, ignore_errors=True)
                raise

    def records(self) -> Iterable[TraceRecord]:
        for directory in sorted(self.root.iterdir()):
            if directory.name.startswith("."):
                continue
            if directory.is_symlink() or not directory.is_dir():
                raise ContractError("trace root contains an unsafe entry")
            metadata_path = directory / "trace.json"
            request_path = directory / "request.json"
            if (
                metadata_path.is_symlink()
                or request_path.is_symlink()
                or not metadata_path.is_file()
                or not request_path.is_file()
            ):
                raise ContractError("trace record is incomplete or unsafe")
            if (
                metadata_path.stat().st_size > MAXIMUM_TRACE_METADATA_BYTES
                or request_path.stat().st_size > MAXIMUM_TRACE_REQUEST_BYTES
            ):
                raise ContractError("trace record exceeds configured bounds")
            metadata = json.loads(metadata_path.read_text())
            body = request_path.read_bytes()
            if metadata.get("schemaVersion") != TRACE_SCHEMA:
                raise ContractError("trace schema is unsupported")
            if hashlib.sha256(body).hexdigest() != metadata.get("requestSHA256"):
                raise ContractError("trace request checksum does not match")
            if metadata.get("outcome") not in {"accepted", "rejected"}:
                raise ContractError("trace outcome is invalid")
            yield TraceRecord(directory, metadata, body)


def replay_traces(
    localizer: ReplayLocalizer,
    trace_store: LocalizationTraceStore,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    accepted = 0
    rejected = 0
    regressions = 0
    durations: list[float] = []
    for record in trace_store.records():
        observation = QueryObservation.parse(json.loads(record.request_body))
        if (
            record.metadata.get("map") != observation.map.json()
            or record.metadata.get("sessionID") != str(observation.session_id).upper()
            or record.metadata.get("frameID") != observation.frame_id
            or record.metadata.get("capturedAt") != observation.captured_at
        ):
            raise ContractError("trace metadata does not match its calibrated request")
        started = perf_counter()
        try:
            output = localizer.localize(observation)
            duration = perf_counter() - started
            actual = "accepted"
            accepted += 1
            stage = "accepted"
            diagnostics = output.metrics.json()
        except LocalizationError as error:
            duration = perf_counter() - started
            actual = "rejected"
            rejected += 1
            stage = error.stage
            diagnostics = error.diagnostics
        durations.append(duration)
        expected = record.metadata.get("outcome")
        changed = actual != expected
        regressions += int(changed)
        results.append({
            "trace": record.directory.name,
            "expectedOutcome": expected,
            "actualOutcome": actual,
            "outcomeChanged": changed,
            "stage": stage,
            "durationMilliseconds": duration * 1_000,
            "diagnostics": diagnostics,
        })
    if not results:
        raise ContractError("replay trace directory contains no records")
    ordered = sorted(durations)
    percentile_index = lambda fraction: min(len(ordered) - 1, int((len(ordered) - 1) * fraction))
    timing = None if not ordered else {
        "medianMilliseconds": ordered[len(ordered) // 2] * 1_000,
        "p95Milliseconds": ordered[percentile_index(0.95)] * 1_000,
        "maximumMilliseconds": ordered[-1] * 1_000,
    }
    return {
        "schemaVersion": 1,
        "map": localizer.server_map.reference.json(),
        "models": localizer.server_map.model_identity,
        "traceCount": len(results),
        "acceptedCount": accepted,
        "rejectedCount": rejected,
        "outcomeRegressionCount": regressions,
        "timing": timing,
        "results": results,
    }
