from __future__ import annotations

import asyncio
import json
from time import perf_counter
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .contracts import QueryObservation
from .errors import ContractError, LocalizationError
from .localizer import MetricVisualLocalizer
from .traces import LocalizationTraceStore


MAXIMUM_REQUEST_BYTES = 12 * 1024 * 1024


def create_app(
    localizer: MetricVisualLocalizer,
    trace_store: LocalizationTraceStore | None = None,
) -> FastAPI:
    app = FastAPI(
        title="HouseMapper Localization",
        version="1.0.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    inference_lock = asyncio.Lock()
    trace_state = {"writeFailures": 0}

    async def record_trace_safely(**values) -> None:
        if trace_store is None:
            return
        try:
            await asyncio.to_thread(trace_store.record, **values)
        except Exception:
            # Evaluation capture must never change a localization decision.
            trace_state["writeFailures"] += 1

    @app.middleware("http")
    async def bounded_json_only(request: Request, call_next):
        if request.method == "POST" and request.url.path == "/localize":
            if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
                return JSONResponse({"detail": "application/json required"}, status_code=415)
            length = request.headers.get("content-length")
            if length is not None:
                try:
                    if int(length) > MAXIMUM_REQUEST_BYTES:
                        return JSONResponse({"detail": "request too large"}, status_code=413)
                except ValueError:
                    return JSONResponse({"detail": "invalid content length"}, status_code=400)
        return await call_next(request)

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {
            "status": "ready",
            "map": localizer.server_map.reference.json(),
            "models": localizer.server_map.model_identity,
            "landmarks": len(localizer.server_map.landmark_ids),
            "tracing": {
                "enabled": trace_store is not None,
                "writeFailures": trace_state["writeFailures"],
            },
        }

    @app.post("/localize")
    async def localize(request: Request):
        observation = None
        body = bytearray()
        started = perf_counter()
        try:
            async for chunk in request.stream():
                if len(body) + len(chunk) > MAXIMUM_REQUEST_BYTES:
                    return JSONResponse({"detail": "request too large"}, status_code=413)
                body.extend(chunk)
            if not body:
                return JSONResponse({"detail": "request body required"}, status_code=400)
            value = json.loads(body)
            observation = QueryObservation.parse(value)
            async with inference_lock:
                output = await asyncio.to_thread(localizer.localize, observation)
            duration = perf_counter() - started
            await record_trace_safely(
                request_body=bytes(body),
                observation=observation,
                outcome="accepted",
                duration_seconds=duration,
                stage="accepted",
                diagnostics=output.metrics.json(),
            )
            response = JSONResponse(output.response)
            response.headers["X-HouseMapper-Inliers"] = str(output.metrics.inliers)
            response.headers["X-HouseMapper-Latency-Ms"] = f"{duration * 1_000:.2f}"
            return response
        except (ContractError, json.JSONDecodeError, UnicodeDecodeError) as error:
            return JSONResponse({"detail": str(error)}, status_code=400)
        except LocalizationError as error:
            duration = perf_counter() - started
            if observation is not None:
                await record_trace_safely(
                    request_body=bytes(body),
                    observation=observation,
                    outcome="rejected",
                    duration_seconds=duration,
                    stage=error.stage,
                    diagnostics=error.diagnostics,
                    detail=str(error),
                )
            return JSONResponse(
                {
                    "detail": str(error),
                    "stage": error.stage,
                    "diagnostics": error.diagnostics,
                },
                status_code=422,
            )
        except Exception:
            # Do not leak home-map paths, model internals, or stack traces.
            return JSONResponse({"detail": "localization failed"}, status_code=500)

    return app
