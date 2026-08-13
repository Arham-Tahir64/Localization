from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from car_slam.common.dataset import load_sequence
from car_slam.common.evaluation import evaluate_run
from car_slam.common.synthetic_sequence import generate_sequence


METHODS = {
    "geometric": ("car_slam.approach_geometric.cli", "--sequence"),
    "learned": ("car_slam.approach_learned", "--manifest"),
    "hybrid": ("car_slam.hybrid", "--sequence"),
}


def _run_method(name: str, manifest: Path, output: Path, backend: str) -> None:
    module, input_flag = METHODS[name]
    command = [sys.executable, "-m", module, input_flag, str(manifest), "--output", str(output)]
    if name in ("learned", "hybrid"):
        command.extend(("--backend", backend, "--max-keypoints", "800"))
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    python_path = [str(root), str(root / "server")]
    if environment.get("PYTHONPATH"):
        python_path.append(environment["PYTHONPATH"])
    environment["PYTHONPATH"] = os.pathsep.join(python_path)
    completed = subprocess.run(
        command,
        cwd=root,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"{name} benchmark failed ({completed.returncode}):\n{completed.stderr[-4000:]}"
        )


def run_benchmark(
    manifest: Path,
    output_directory: Path,
    *,
    backend: str = "sift-proxy",
) -> dict[str, object]:
    sequence = load_sequence(manifest)
    output_directory.mkdir(parents=True, exist_ok=True)
    evaluations: dict[str, object] = {}
    for name in METHODS:
        result_path = output_directory / f"{name}-result.json"
        _run_method(name, manifest, result_path, backend)
        evaluations[name] = evaluate_run(sequence, result_path)
    comparison = {
        "schemaVersion": 1,
        "sequence": sequence.name,
        "appearanceBackend": backend,
        "methods": evaluations,
        "limitations": [
            "Synthetic sequences are regression proxies, not evidence of road performance.",
            "Monocular trajectories use Sim(3) alignment; metric scale is not observed without another sensor.",
            "Each method runs in a fresh process so CPU time and peak RSS are not inherited from another method.",
        ],
    }
    (output_directory / "comparison.json").write_text(
        json.dumps(comparison, indent=2, sort_keys=True) + "\n"
    )
    return comparison


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the isolated common car-SLAM benchmark")
    parser.add_argument("--sequence", type=Path, help="existing common sequence manifest")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backend", choices=("sift-proxy", "learned"), default="sift-proxy")
    parser.add_argument("--generated-frames", type=int, default=180)
    arguments = parser.parse_args(argv)
    if arguments.sequence:
        manifest = arguments.sequence.resolve()
        temporary = None
    else:
        temporary = tempfile.TemporaryDirectory(prefix="car-slam-benchmark-")
        manifest = generate_sequence(Path(temporary.name), frames=arguments.generated_frames)
    comparison = run_benchmark(manifest, arguments.output.resolve(), backend=arguments.backend)
    print(json.dumps(comparison, indent=2, sort_keys=True))
    if temporary is not None:
        temporary.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
