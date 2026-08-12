from __future__ import annotations

import asyncio
import json
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .contracts import QueryObservation
from .errors import ContractError, LocalizationError
from .localizer import MetricVisualLocalizer


MAXIMUM_REQUEST_BYTES = 12 * 1024 * 1024


def create_app(localizer: MetricVisualLocalizer) -> FastAPI:
    app = FastAPI(
        title="HouseMapper Localization",
        version="1.0.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    inference_lock = asyncio.Lock()

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
        }

    @app.post("/localize")
    async def localize(request: Request):
        try:
            body = bytearray()
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
            response = JSONResponse(output.response)
            response.headers["X-HouseMapper-Inliers"] = str(output.metrics.inliers)
            response.headers["X-HouseMapper-Latency-Ms"] = f"{sum((output.metrics.extraction_seconds, output.metrics.retrieval_seconds, output.metrics.matching_seconds, output.metrics.pnp_seconds)) * 1_000:.2f}"
            return response
        except (ContractError, json.JSONDecodeError, UnicodeDecodeError) as error:
            return JSONResponse({"detail": str(error)}, status_code=400)
        except LocalizationError as error:
            return JSONResponse({"detail": str(error)}, status_code=422)
        except Exception:
            # Do not leak home-map paths, model internals, or stack traces.
            return JSONResponse({"detail": "localization failed"}, status_code=500)

    return app
