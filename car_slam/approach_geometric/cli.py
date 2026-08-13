from __future__ import annotations

import argparse
import json
from pathlib import Path

from .io import load_kitti, load_manifest
from .pipeline import GeometricSLAM
from .pipeline import run_sequence
from .replay import generated_replay


def main(argv=None):
    parser = argparse.ArgumentParser(description="Classical monocular car-camera SLAM")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--manifest", type=Path)
    source.add_argument("--kitti", type=Path)
    source.add_argument("--sequence", type=Path, help="shared car-SLAM sequence manifest")
    parser.add_argument("--poses", type=Path)
    parser.add_argument("--generated-frames", type=int, default=90)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if args.sequence:
        from car_slam.common.dataset import load_sequence
        from car_slam.common.evaluation import evaluate_run
        sequence = load_sequence(args.sequence)
        result = run_sequence(sequence)
        encoded = json.dumps(result, indent=2, sort_keys=True)
        if args.output: args.output.write_text(encoded + "\n")
        print(json.dumps(evaluate_run(sequence, result), sort_keys=True))
        return result
    frames = load_manifest(args.manifest) if args.manifest else load_kitti(args.kitti, args.poses) if args.kitti else generated_replay(args.generated_frames)
    slam = GeometricSLAM()
    per_frame = [slam.process(frame) for frame in frames]
    result = {"summary": slam.summary(), "frames": per_frame}
    encoded = json.dumps(result, indent=2, sort_keys=True)
    if args.output: args.output.write_text(encoded + "\n")
    print(json.dumps(result["summary"], sort_keys=True))
    return result


if __name__ == "__main__":
    main()
