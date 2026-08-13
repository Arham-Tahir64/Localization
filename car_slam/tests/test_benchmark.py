import json

from car_slam.benchmark import run_benchmark
from car_slam.common.synthetic_sequence import generate_sequence


def test_common_benchmark_runs_all_methods_in_isolated_processes(tmp_path):
    manifest = generate_sequence(tmp_path / "sequence", frames=12)
    comparison = run_benchmark(manifest, tmp_path / "results")
    assert set(comparison["methods"]) == {"geometric", "learned", "hybrid"}
    assert comparison["sequence"] == "deterministic-car-geometry-v1"
    saved = json.loads((tmp_path / "results" / "comparison.json").read_text())
    assert saved["appearanceBackend"] == "sift-proxy"
    for method in comparison["methods"].values():
        assert method["frames"] == 12
