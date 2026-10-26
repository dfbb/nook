#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--xctrace TEMPLATE] [--only ID[,ID...]] <label> <lib-name-or-path> <script.json> [variant]" >&2
  exit 2
}

xctrace_template=""
only=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --xctrace) [[ $# -ge 2 ]] || usage; xctrace_template="$2"; shift 2 ;;
    --only) [[ $# -ge 2 ]] || usage; only="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ $# -ge 3 && $# -le 4 ]] || usage
[[ -z "$only" || "$only" =~ ^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$ ]] || { echo "invalid --only (step ids, comma-separated): $only" >&2; exit 2; }

label="$1"
lib_arg="$2"
script_arg="$3"
variant="${4:-none}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# `make perf-build` (-O, DEBUG instrumentation kept). NOOK_PERF_APP points
# elsewhere, e.g. at the -Onone `make build` app, which also needs
# NOOK_PERF_ALLOW_ONONE=1 to pass the check after the run.
app="${NOOK_PERF_APP:-$repo_root/DerivedData-perf/Build/Products/Debug/Nook.app}"
executable="$app/Contents/MacOS/Nook"
# Never let an override launch the user's installed app.
if [[ "$app" -ef /Applications/Nook.app ]]; then
  echo "refusing to launch the installed /Applications/Nook.app" >&2
  exit 2
fi
port=8765
library_timeout="${NOOK_PERF_LIBRARY_TIMEOUT_SECONDS:-60}"
case "$(basename "$script_arg")" in refresh*) default_cap=300 ;; *) default_cap=600 ;; esac
run_timeout="${NOOK_PERF_RUN_TIMEOUT_SECONDS:-$default_cap}"
for limit in "$library_timeout" "$run_timeout"; do
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "timeouts must be positive integer seconds" >&2; exit 2; }
done

# The label becomes a path under perf-runs/ that rsync --delete writes into.
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid label (use [A-Za-z0-9._-], no leading dot): $label" >&2; exit 2; }
case "$variant" in none | trickle | burst | big1) ;; *) echo "unknown feed variant: $variant" >&2; exit 2 ;; esac

if [[ -d "$lib_arg" ]]; then
  golden="$(cd "$lib_arg" && pwd)"
else
  golden="$repo_root/perf-data/golden/$lib_arg"
fi
[[ -d "$golden" ]] || { echo "golden library not found: $golden" >&2; exit 1; }
[[ -f "$script_arg" ]] || { echo "scenario script not found: $script_arg" >&2; exit 1; }
[[ -x "$executable" ]] || { echo "perf app not found: $app (run make perf-build first)" >&2; exit 1; }

lib_name="$(basename "$golden")"
script_name="$(basename "$script_arg")"
script_name="${script_name%.*}"
# The log name keeps the step, so per-step launches stay apart in perf-runs/.
[[ -z "$only" ]] || script_name="$script_name-${only//,/+}"
data_root="$(cd "$golden/../.." && pwd)"
# Feed XML is generated per library, so lib-10k never serves lib-20k's items.
feed_root="$data_root/feeds/$lib_name/$variant"
[[ -d "$feed_root" ]] || { echo "feed variant not found: $feed_root (regenerate $lib_name)" >&2; exit 1; }

port_open() {
  python3 -c 'import socket, sys; s=socket.socket(); s.settimeout(.1); ok=s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0; s.close(); raise SystemExit(0 if ok else 1)' "$port" 2>/dev/null
}
# A leftover server on the port would answer the readiness probe with the wrong variant.
if port_open; then
  echo "port $port is already in use; stop the stale feed server first (lsof -nP -iTCP:$port)" >&2
  exit 1
fi

run_dir="$repo_root/perf-runs/$label"
# The working copy keeps the library's own name so run.begin logs lib=<lib_name>.
# No excludes: --delete also resets the perf replica (<dir>/.nook-perf-replica).
working="$repo_root/perf-runs/.work/$label/$script_name-$variant/$lib_name"
mkdir -p "$run_dir" "$working"
rsync -a --delete "$golden/" "$working/"

server_log="$run_dir/feedserver-$lib_name-$script_name-$variant.log"
python3 "$repo_root/tools/perf/feedserver.py" --root "$feed_root" --port "$port" --latency-seed 7 >"$server_log" 2>&1 &
server_pid=$!
child_pid=""
watchdog_pid=""
trace_pid=""
stop_child() {
  [[ -n "$child_pid" ]] || return 0
  kill "$child_pid" 2>/dev/null || true
  # A stuck app may ignore SIGTERM. Target only the child we launched.
  sleep 1
  kill -KILL "$child_pid" 2>/dev/null || true
}
cleanup() {
  [[ -z "$trace_pid" ]] || kill -INT "$trace_pid" 2>/dev/null || true
  [[ -z "$watchdog_pid" ]] || kill "$watchdog_pid" 2>/dev/null || true
  if [[ -n "$child_pid" ]]; then
    stop_child
    wait "$child_pid" 2>/dev/null || true
  fi
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

server_ready=0
for _ in {1..50}; do
  if kill -0 "$server_pid" 2>/dev/null; then
    if port_open; then
      server_ready=1
      break
    fi
  else
    echo "feed server exited early; see $server_log" >&2
    exit 1
  fi
  sleep 0.1
done
[[ "$server_ready" -eq 1 ]] || { echo "feed server did not become ready; see $server_log" >&2; exit 1; }

sha="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  sha="${sha}-dirty"
fi
head_time="$(git -C "$repo_root" log -1 --format=%ct 2>/dev/null || echo 0)"
binary_time="$(stat -f %m "$executable" 2>/dev/null || echo 0)"
if [[ "$head_time" =~ ^[0-9]+$ && "$binary_time" =~ ^[0-9]+$ && "$binary_time" -lt "$head_time" ]]; then
  echo "warning: Nook binary is older than HEAD; run make perf-build before trusting sha=$sha" >&2
fi
launch_args=(
  -ApplePersistenceIgnoreState YES
  -NSQuitAlwaysKeepsWindows NO
  -NookPerfLibrary "$working"
  -NookPerfScript "$(cd "$(dirname "$script_arg")" && pwd)/$(basename "$script_arg")"
  -NookPerfLabel "$label"
  -NookPerfSHA "$sha"
  -NookStallMs 50
  -autoRefreshEnabled NO
  -NookFaviconFetch NO
  -NookAICategorize NO
  -NookFreezeRelativeTime
)
[[ -z "$only" ]] || launch_args+=(-NookPerfOnly "$only")

# Give this child an explicit log path: macOS Foundation can ignore TMPDIR.
# Never inspect or move the real app's container log.
launch_tmp="$(mktemp -d "$working/../launch.XXXXXX")"
source_log="$launch_tmp/ui-forensics.log"
n=1
while [[ -e "$run_dir/$lib_name-$script_name-$variant-$n.log" ]]; do n=$((n + 1)); done
destination="$run_dir/$lib_name-$script_name-$variant-$n.log"
timeout_marker="$launch_tmp/timeout"
launch_args+=(-NookPerfLog "$source_log")

TMPDIR="$launch_tmp/" "$executable" "${launch_args[@]}" >"$launch_tmp/stdout.log" 2>"$launch_tmp/stderr.log" &
child_pid=$!
if [[ -n "$xctrace_template" ]]; then
  # Attach by PID so the watchdog always owns the actual app child.
  trace="$run_dir/$lib_name-$script_name-$variant-$(date +%Y%m%d-%H%M%S).trace"
  xcrun xctrace record --template "$xctrace_template" --output "$trace" --time-limit "${run_timeout}s" --attach "$child_pid" &
  trace_pid=$!
fi
(
  started=$SECONDS
  while kill -0 "$child_pid" 2>/dev/null; do
    elapsed=$((SECONDS - started))
    if (( elapsed >= run_timeout )); then
      echo "total" >"$timeout_marker"
      break
    fi
    if (( elapsed >= library_timeout )) && ! grep -q 'perf\.library' "$source_log" 2>/dev/null; then
      echo "library" >"$timeout_marker"
      break
    fi
    sleep 1
  done
  if [[ -f "$timeout_marker" ]]; then stop_child; fi
) &
watchdog_pid=$!
status=0
wait "$child_pid" || status=$?
# Wait for a timeout's TERM/KILL sequence before dropping the child handle.
if [[ -f "$timeout_marker" ]]; then
  wait "$watchdog_pid" || true
else
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
fi
watchdog_pid=""
child_pid=""
if [[ -n "$trace_pid" ]]; then
  kill -INT "$trace_pid" 2>/dev/null || true
  trace_status=0
  wait "$trace_pid" || trace_status=$?
  trace_pid=""
  if [[ "$status" -eq 0 && "$trace_status" -ne 0 ]]; then status=$trace_status; fi
fi

if [[ -f "$source_log" ]]; then mv "$source_log" "$destination"; else touch "$destination"; fi
if [[ -f "$timeout_marker" ]]; then
  echo "perf.driver.error reason=launch-timeout phase=$(cat "$timeout_marker") libraryLimit=$library_timeout totalLimit=$run_timeout" >>"$destination"
  echo "launch timed out; see $destination" >&2
  status=124
elif [[ "$status" -ne 0 ]]; then
  echo "perf.driver.error reason=child-exit status=$status" >>"$destination"
elif ! grep -q 'perf\.library' "$destination"; then
  echo "perf.driver.error reason=missing-library" >>"$destination"
  status=1
fi
echo "$destination"
[[ "$status" -eq 0 ]] || exit "$status"
if grep -q 'perf\.driver\.error' "$destination"; then exit 1; fi

# -Onone inflates app-code cost several times; keep it out of -O results.
opt="$(sed -n 's/.*run\.begin.* opt=\([^ ]*\).*/\1/p' "$destination" | tail -1)"
if [[ "$opt" != "-O" ]]; then
  echo "warning: this run was built with opt=${opt:-unknown}, not -O; measure with make perf-build" >&2
  [[ "${NOOK_PERF_ALLOW_ONONE:-0}" == "1" ]] || exit 1
fi
