from __future__ import annotations

import argparse
import json
from pathlib import Path

from car_slam.common.dataset import load_sequence
from car_slam.common.synthetic_sequence import generate_sequence
from .pipeline import LearnedSLAMConfig, run_sequence


def backend_named(name: str, maximum_keypoints: int):
    from server.housemapper_server.features import LearnedLightGlueBackend, SIFTBaselineBackend
    if name == "learned":
        return LearnedLightGlueBackend(maximum_keypoints=maximum_keypoints)
    return SIFTBaselineBackend(maximum_keypoints=maximum_keypoints)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Appearance-first car monocular SLAM replay")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--backend", choices=("learned", "sift-proxy"), default="sift-proxy")
    parser.add_argument("--frames", type=int, default=180, help="generated common-sequence frame count")
    parser.add_argument("--max-keypoints", type=int, default=800)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if args.manifest:
        sequence = load_sequence(args.manifest)
    else:
        import tempfile
        generated_root = Path(tempfile.mkdtemp(prefix="car-slam-learned-"))
        sequence = load_sequence(generate_sequence(generated_root, frames=args.frames))
    payload = run_sequence(sequence, backend_named(args.backend, args.max_keypoints), LearnedSLAMConfig())
    encoded = json.dumps(payload, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(encoded + "\n")
    print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
