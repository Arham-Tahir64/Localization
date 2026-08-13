from __future__ import annotations

import argparse
import json
from pathlib import Path

from car_slam.common.dataset import load_sequence
from car_slam.common.evaluation import evaluate_run
from server.housemapper_server.features import LearnedLightGlueBackend, SIFTBaselineBackend

from .pipeline import run_sequence


def main(argv=None):
    parser = argparse.ArgumentParser(description="Sequential geometry-authority car SLAM hybrid")
    parser.add_argument("--sequence", type=Path, required=True)
    parser.add_argument("--backend", choices=("learned", "sift-proxy"), default="sift-proxy")
    parser.add_argument("--max-keypoints", type=int, default=800)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    sequence = load_sequence(args.sequence)
    backend = LearnedLightGlueBackend(maximum_keypoints=args.max_keypoints) if args.backend == "learned" else SIFTBaselineBackend(args.max_keypoints)
    result = run_sequence(sequence, backend)
    encoded = json.dumps(result, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(encoded + "\n")
    print(json.dumps(evaluate_run(sequence, result), indent=2, sort_keys=True))
    return result


if __name__ == "__main__":
    main()
