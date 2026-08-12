from __future__ import annotations

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import sys

from .builder import build_metric_map
from .contracts import MappingPackage
from .errors import HouseMapperServerError
from .features import LearnedLightGlueBackend, SIFTBaselineBackend
from .localizer import MetricVisualLocalizer
from .map_store import load_server_map
from .traces import LocalizationTraceStore, replay_traces


def _backend(name: str, device: str):
    if name == "learned":
        return LearnedLightGlueBackend(device=device)
    if name == "sift-baseline":
        return SIFTBaselineBackend()
    raise ValueError(name)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="housemapper-server")
    commands = root.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate-package", help="fail-closed validation of an exported HouseMapper package")
    validate.add_argument("package", type=Path)

    build = commands.add_parser("build", help="construct an immutable metric learned-feature map")
    build.add_argument("package", type=Path)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--endpoint", required=True, help="iPhone-reachable /localize URL, normally http://NAME.local:8080/localize")
    build.add_argument("--backend", choices=("learned", "sift-baseline"), default="learned")
    build.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")

    serve = commands.add_parser("serve", help="serve exactly one immutable server map")
    serve.add_argument("map", type=Path)
    serve.add_argument("--backend", choices=("learned", "sift-baseline"), default="learned")
    serve.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    serve.add_argument("--host", default="0.0.0.0")
    serve.add_argument("--port", type=int, default=8080)
    serve.add_argument(
        "--trace-directory",
        type=Path,
        help="opt in to storing sensitive replayable query images and diagnostics",
    )

    replay = commands.add_parser("replay", help="re-run a captured query set against one immutable map")
    replay.add_argument("map", type=Path)
    replay.add_argument("traces", type=Path)
    replay.add_argument("--backend", choices=("learned", "sift-baseline"), default="learned")
    replay.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    replay.add_argument("--output", type=Path)

    inspect = commands.add_parser("inspect", help="verify and summarize one immutable server map")
    inspect.add_argument("map", type=Path)
    return root


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "validate-package":
            package = MappingPackage.load(arguments.package)
            print(json.dumps({"mapID": str(package.map_id), "name": package.name, "keyframes": len(package.keyframes)}, indent=2))
        elif arguments.command == "build":
            package = MappingPackage.load(arguments.package)
            result = build_metric_map(
                package,
                _backend(arguments.backend, arguments.device),
                arguments.output,
                arguments.endpoint,
            )
            print(json.dumps({"mapDirectory": str(result.directory), "metrics": asdict(result.metrics)}, indent=2))
            print(f"Attach this file on iPhone: {result.directory / 'server-map.json'}")
        elif arguments.command == "inspect":
            server_map = load_server_map(arguments.map)
            print(json.dumps({
                "map": server_map.reference.json(),
                "models": server_map.model_identity,
                "keyframes": len(server_map.keyframe_ids),
                "keypoints": len(server_map.keypoints),
                "landmarks": len(server_map.landmark_ids),
            }, indent=2))
        elif arguments.command == "serve":
            if arguments.port < 1 or arguments.port > 65535:
                raise HouseMapperServerError("port must be between 1 and 65535")
            import uvicorn
            trace_store = LocalizationTraceStore(arguments.trace_directory) if arguments.trace_directory else None
            app = __import__("housemapper_server.service", fromlist=["create_app"]).create_app(
                MetricVisualLocalizer(
                    load_server_map(arguments.map),
                    _backend(arguments.backend, arguments.device),
                ),
                trace_store,
            )
            uvicorn.run(app, host=arguments.host, port=arguments.port, access_log=False)
        elif arguments.command == "replay":
            report = replay_traces(
                MetricVisualLocalizer(
                    load_server_map(arguments.map),
                    _backend(arguments.backend, arguments.device),
                ),
                LocalizationTraceStore(arguments.traces, create=False),
            )
            encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
            if arguments.output:
                arguments.output.write_text(encoded)
            else:
                print(encoded, end="")
            if report["outcomeRegressionCount"]:
                return 3
        return 0
    except (HouseMapperServerError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
