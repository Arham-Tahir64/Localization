from __future__ import annotations

import argparse
import json

from .evaluation import evaluate_run


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sequence")
    parser.add_argument("result")
    parser.add_argument("--output")
    arguments = parser.parse_args()
    report = evaluate_run(arguments.sequence, arguments.result)
    encoded = json.dumps(report, indent=2, sort_keys=True)
    if arguments.output:
        with open(arguments.output, "w", encoding="utf-8") as destination:
            destination.write(encoded + "\n")
    print(encoded)


if __name__ == "__main__":
    main()
