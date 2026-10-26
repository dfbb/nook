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
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid label: $label" >&2; exit 2; }
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script_dir="${NOOK_PERF_SCRIPTS:-$repo_root/tools/perf/scripts}"
runner="$repo_root/tools/perf/run.sh"
derived_dir="$repo_root/perf-runs/.work/$label/scripts"
reps=5

for group in switch scroll toggle misc; do
  [[ -f "$script_dir/$group.json" ]] || { echo "missing $script_dir/$group.json (set NOOK_PERF_SCRIPTS if scripts live elsewhere)" >&2; exit 1; }
done
# B is split per feed variant (refresh-none/-trickle/-big1.json); an older
# single refresh.json is still accepted.
refresh_scripts=()
for variant in none trickle burst big1; do
  [[ -f "$script_dir/refresh-$variant.json" ]] && refresh_scripts+=("refresh-$variant")
done
[[ ${#refresh_scripts[@]} -gt 0 || -f "$script_dir/refresh.json" ]] || { echo "missing $script_dir/refresh-<variant>.json" >&2; exit 1; }
mkdir -p "$derived_dir"

# Writes a copy of <group>.json holding only the given step ids (or every step
# except them with --except). --single also forces one warm repetition.
derive() {
  local group="$1" name="$2" mode="$3"
  shift 3
  python3 - "$script_dir/$group.json" "$derived_dir/$name.json" "$mode" "$@" <<'PY'
import json, sys
source, target, mode, *ids = sys.argv[1:]
script = json.load(open(source))
keep = (lambda step: step["id"] not in ids) if mode == "except" else (lambda step: step["id"] in ids)
script["steps"] = [step for step in script["steps"] if keep(step)]
missing = set(ids) - {step["id"] for step in json.load(open(source))["steps"]}
if missing:
    sys.exit(f"{source}: no step {sorted(missing)}")
if mode == "single":
    script["repetitions"] = 1
    script["coldFirst"] = False
    for step in script["steps"]:
        step.pop("repetitions", None)
        step.pop("coldFirst", None)
json.dump(script, open(target, "w"), indent=1)
PY
  echo "$derived_dir/$name.json"
}

run() {
  "$runner" ${xctrace[@]+"${xctrace[@]}"} "$label" "$@"
}

# Refresh-driven steps consume their new items on the first rep, so each rep
# is its own launch; run.sh restores the golden library before every launch.
# The log file name carries <step>-<variant>, which perfreport groups by.
run_per_rep() {
  local group="$1" step="$2" lib="$3" variant="$4"
  local script
  script="$(derive "$group" "$group-$step" single "$step")"
  for _ in $(seq "$reps"); do run "$lib" "$script" "$variant"; done
}

# Library and variant coverage follows measurement.md §3/§5.
for lib in lib-5k lib-10k lib-20k; do run "$lib" "$script_dir/switch.json" none; done

step_ids() {
  python3 -c 'import json, sys; print(" ".join(step["id"] for step in json.load(open(sys.argv[1]))["steps"]))' "$script_dir/$1.json"
}
if [[ ${#refresh_scripts[@]} -gt 0 ]]; then
  # Each step still gets its own launches: in refresh-trickle.json, B2 would
  # otherwise consume the new items before B3 and B5 run.
  for group in "${refresh_scripts[@]}"; do
    ids="$(step_ids "$group")"
    for step in $ids; do run_per_rep "$group" "$step" lib-10k "${group#refresh-}"; done
  done
else
  run_per_rep refresh B1 lib-10k none
  run_per_rep refresh B2 lib-10k trickle
  run_per_rep refresh B3 lib-10k trickle
  run_per_rep refresh B4 lib-10k big1
  run_per_rep refresh B5 lib-10k trickle
fi

scroll_rest="$(derive scroll scroll except C4)"
for lib in lib-10k lib-20k; do
  run "$lib" "$scroll_rest" none
  run_per_rep scroll C4 "$lib" trickle
done

run lib-10k "$script_dir/toggle.json" none

misc_rest="$(derive misc misc except E3)"
run lib-10k "$misc_rest" none
run_per_rep misc E3 lib-10k trickle
