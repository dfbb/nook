#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--xctrace TEMPLATE] <label>" >&2
  exit 2
}

xctrace=()
if [[ "${1:-}" == "--xctrace" ]]; then
  [[ $# -eq 3 ]] || usage
  xctrace=(--xctrace "$2")
  shift 2
fi
[[ $# -eq 1 ]] || usage

label="$1"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script_dir="${NOOK_PERF_SCRIPTS:-$repo_root/tools/perf/scripts}"
runner="$repo_root/tools/perf/run.sh"

run_group() {
  local group="$1" lib="$2" variant="$3"
  local script="$script_dir/$group.json"
  [[ -f "$script" ]] || { echo "missing $script (set NOOK_PERF_SCRIPTS if scripts live elsewhere)" >&2; exit 1; }
  "$runner" "${xctrace[@]}" "$label" "$lib" "$script" "$variant"
}

# Library coverage follows measurement.md: A=5k/10k/20k, B=10k,
# C=10k/20k, D=10k. E is the extended 10k classification/offline group.
for lib in lib-5k lib-10k lib-20k; do run_group A "$lib" none; done
run_group B lib-10k none
run_group B lib-10k trickle
run_group B lib-10k big1
run_group C lib-10k trickle
run_group C lib-20k trickle
run_group D lib-10k none
run_group E lib-10k trickle
