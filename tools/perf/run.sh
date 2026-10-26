#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--xctrace TEMPLATE] <label> <lib-name-or-path> <script.json> [variant]" >&2
  exit 2
}

xctrace_template=""
if [[ "${1:-}" == "--xctrace" ]]; then
  [[ $# -ge 3 ]] || usage
  xctrace_template="$2"
  shift 2
fi
[[ $# -ge 3 && $# -le 4 ]] || usage

label="$1"
lib_arg="$2"
script_arg="$3"
variant="${4:-none}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$repo_root/DerivedData/Build/Products/Debug/Nook.app"
executable="$app/Contents/MacOS/Nook"
port=8765

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
[[ -d "$app" ]] || { echo "debug app not found: $app (run make build first)" >&2; exit 1; }

lib_name="$(basename "$golden")"
script_name="$(basename "$script_arg")"
script_name="${script_name%.*}"
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
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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
  echo "warning: Nook binary is older than HEAD; rebuild before trusting sha=$sha" >&2
fi
launch_args=(
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

# MainThreadLog appends to NSTemporaryDirectory()/ui-forensics.log: the user
# temp dir for an unsigned (CODE_SIGNING_ALLOWED=NO) build. The real app
# container is considered only for a verifiably signed build, avoiding a TCC
# prompt and the user's own debug log during normal perf runs.
candidates=()
for dir in "${TMPDIR:-}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"; do
  [[ -n "$dir" ]] || continue
  path="${dir%/}/ui-forensics.log"
  for seen in ${candidates[@]+"${candidates[@]}"}; do [[ "$seen" -ef "$path" || "$seen" == "$path" ]] && continue 2; done
  candidates+=("$path")
done
if codesign --verify "$app" >/dev/null 2>&1; then
  container_log="$HOME/Library/Containers/com.tim.nook/Data/tmp/ui-forensics.log"
  candidates+=("$container_log")
fi
# Archive any earlier log so the file after this launch holds only this run.
archive="$repo_root/perf-runs/.work/$label/archived-logs"
for candidate in "${candidates[@]}"; do
  if [[ -f "$candidate" ]]; then
    mkdir -p "$archive"
    archived="$archive/$(date +%Y%m%d-%H%M%S)-$RANDOM-ui-forensics.log"
    mv "$candidate" "$archived"
    echo "archived existing perf log: $candidate -> $archived" >&2
  fi
done

if [[ -n "$xctrace_template" ]]; then
  trace="$run_dir/$lib_name-$script_name-$variant-$(date +%Y%m%d-%H%M%S).trace"
  xcrun xctrace record --template "$xctrace_template" --output "$trace" --launch -- "$executable" "${launch_args[@]}"
else
  open -n -W "$app" --args "${launch_args[@]}"
fi

n=1
while [[ -e "$run_dir/$lib_name-$script_name-$variant-$n.log" ]]; do n=$((n + 1)); done
destination="$run_dir/$lib_name-$script_name-$variant-$n.log"

found=0
for candidate in "${candidates[@]}"; do
  [[ -f "$candidate" ]] || continue
  begin="$(grep 'run\.begin' "$candidate" | grep "label=$label " | tail -1 || true)"
  [[ -n "$begin" ]] || continue
  # Prefer the path the app declared in run.begin; it is the same file unless
  # the temp dir resolved differently inside the app.
  declared="$(printf '%s\n' "$begin" | sed -n 's/.* log=\([^ ]*\).*/\1/p')"
  [[ -n "$declared" && -f "$declared" ]] || declared="$candidate"
  mv "$declared" "$destination"
  found=1
  break
done

[[ "$found" -eq 1 ]] || {
  echo "could not locate this launch's ui-forensics.log for label=$label (checked: ${candidates[*]})" >&2
  exit 1
}
echo "$destination"
