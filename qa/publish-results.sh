#!/bin/bash
# Copies one run folder into the results repo clone and pushes it.
# Usage: RESULTS_REPO_DIR=/path/to/fleet-scale-results ./publish-results.sh <local|aws> <run dir>
set -euo pipefail
target="${1:?usage: publish-results.sh <local|aws> <run dir>}"
run="${2:?usage: publish-results.sh <local|aws> <run dir>}"
repo="${RESULTS_REPO_DIR:?set RESULTS_REPO_DIR to your results repo clone}"
name="$(basename "$run")"
mkdir -p "$repo/$target/$name"
cp "$run"/*.jsonl "$repo/$target/$name/"
git -C "$repo" add "$target/$name"
git -C "$repo" commit -m "Results: $target $name"
git -C "$repo" push
