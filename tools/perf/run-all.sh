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
run_dir="$repo_root/perf-runs/$label"
derived_dir="$repo_root/perf-runs/.work/$label/scripts"
reps=5

if [[ -d "$run_dir" ]] && [[ -n "$(find "$run_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "refusing to mix repetitions: $run_dir is not empty (choose a new label)" >&2
  exit 1
fi

for group in switch scroll toggle misc; do
  [[ -f "$script_dir/$group.json" ]] || { echo "missing $script_dir/$group.json (set NOOK_PERF_SCRIPTS if scripts live elsewhere)" >&2; exit 1; }
done
# B is split per feed variant (refresh-none/-trickle/-big1.json); an older
# single refresh.json is still accepted.
refresh_scripts=()
for variant in none trickle big1; do
  [[ -f "$script_dir/refresh-$variant.json" ]] && refresh_scripts+=("refresh-$variant")
done
if [[ ${#refresh_scripts[@]} -ne 0 && ${#refresh_scripts[@]} -ne 3 ]]; then
  echo "incomplete split refresh scripts: need refresh-{none,trickle,big1}.json" >&2
  exit 1
fi
[[ ${#refresh_scripts[@]} -eq 3 || -f "$script_dir/refresh.json" ]] || { echo "missing $script_dir/refresh-{none,trickle,big1}.json (or legacy refresh.json)" >&2; exit 1; }
mkdir -p "$derived_dir" "$run_dir"

# Writes a copy of <group>.json. Mode except drops the given step ids; mode
# single keeps every step and forces one repetition with no cold rep, and
# run.sh --only then picks the step.
derive() {
  local group="$1" name="$2" mode="$3"
  shift 3
  python3 - "$script_dir/$group.json" "$derived_dir/$name.json" "$mode" "$@" <<'PY' || return $?
import json, sys
source, target, mode, *ids = sys.argv[1:]
script = json.load(open(source))
keep = (lambda step: step["id"] not in ids) if mode == "except" else (lambda step: True)
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

run_only() {
  local step="$1"
  shift
  "$runner" ${xctrace[@]+"${xctrace[@]}"} --only "$step" "$label" "$@"
}

# Refresh-driven steps consume their new items on the first rep, so each rep
# is its own launch; run.sh restores the golden library before every launch.
# The log file name carries <step>-<variant> (run.sh appends the --only id).
# The one rep is the step's sample by design, so the script states coldFirst
# false and the driver adds no cold rep before it.
run_per_rep() {
  local group="$1" step="$2" lib="$3" variant="$4"
  local script
  script="$(derive "$group" "$group-single" single)" || return $?
  for _ in $(seq "$reps"); do run_only "$step" "$lib" "$script" "$variant" || return $?; done
}

# A failed launch aborts its group; independent groups still run.
step_ids() {
  python3 -c 'import json, sys; print(" ".join(step["id"] for step in json.load(open(sys.argv[1]))["steps"]))' "$script_dir/$1.json"
}

group_switch() {
  local lib
  for lib in lib-5k lib-10k lib-20k; do run "$lib" "$script_dir/switch.json" none || return $?; done
}
group_refresh() {
  local group ids step
  if [[ ${#refresh_scripts[@]} -gt 0 ]]; then
    for group in "${refresh_scripts[@]}"; do
      ids="$(step_ids "$group")" || return $?
      for step in $ids; do run_per_rep "$group" "$step" lib-10k "${group#refresh-}" || return $?; done
    done
  else
    run_per_rep refresh B1 lib-10k none || return $?
    run_per_rep refresh B2 lib-10k trickle || return $?
    run_per_rep refresh B3 lib-10k trickle || return $?
    run_per_rep refresh B4 lib-10k big1 || return $?
    run_per_rep refresh B5 lib-10k trickle || return $?
  fi
}
group_scroll() {
  local script lib
  script="$(derive scroll scroll except C4)" || return $?
  for lib in lib-10k lib-20k; do
    run "$lib" "$script" none || return $?
    run_per_rep scroll C4 "$lib" trickle || return $?
  done
}
group_toggle() { run lib-10k "$script_dir/toggle.json" none; }
group_misc() {
  local script
  script="$(derive misc misc except E3)" || return $?
  run lib-10k "$script" none || return $?
  run_per_rep misc E3 lib-10k trickle
}

# Ctrl-C reaches run.sh and this script alike: stop the whole matrix, not
# just the current launch.
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
summary="$run_dir/groups.txt"
for group in switch refresh scroll toggle misc; do
  if case "$group" in
    switch) group_switch ;; refresh) group_refresh ;; scroll) group_scroll ;;
    toggle) group_toggle ;; misc) group_misc ;;
  esac; then
    echo "$group: succeeded" | tee -a "$summary"
  else
    status=$?
    if [[ "$status" -eq 130 || "$status" -eq 143 ]]; then
      echo "$group: aborted (exit=$status; remaining groups skipped)" | tee -a "$summary" >&2
      exit "$status"
    fi
    echo "$group: failed (exit=$status; remaining launches in group skipped)" | tee -a "$summary" >&2
    failed=1
  fi
done
cat "$summary"
exit "$failed"
