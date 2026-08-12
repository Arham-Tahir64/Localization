#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_path="${TMPDIR:-/tmp}/housemapper-spatial-console-benchmark"
module_cache_path="${TMPDIR:-/tmp}/housemapper-spatial-console-module-cache"

xcrun swiftc -O \
  -module-cache-path "$module_cache_path" \
  "$repo_root/HouseMapper/Models/MapMetadata.swift" \
  "$repo_root/HouseMapper/Models/FeaturePointSnapshot.swift" \
  "$repo_root/Benchmarks/SpatialConsoleBenchmark/main.swift" \
  -o "$output_path"

"$output_path"
