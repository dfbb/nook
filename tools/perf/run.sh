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
feed_root="$data_root/feeds/$variant"
[[ -d "$feed_root" ]] || { echo "feed variant not found: $feed_root" >&2; exit 1; }

run_dir="$repo_root/perf-runs/$label"
working="$repo_root/perf-runs/.work/$label/$lib_name-$script_name-$variant"
mkdir -p "$run_dir" "$working"
rsync -a --delete "$golden/" "$working/"

server_log="$run_dir/feedserver-$lib_name-$script_name-$variant.log"
python3 "$repo_root/tools/perf/feedserver.py" --root "$feed_root" --port 8765 --latency-seed 7 >"$server_log" 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

server_ready=0
for _ in {1..50}; do
  if kill -0 "$server_pid" 2>/dev/null; then
    if python3 -c 'import socket; s=socket.socket(); s.settimeout(.1); ok=s.connect_ex(("127.0.0.1",8765)) == 0; s.close(); raise SystemExit(0 if ok else 1)' 2>/dev/null; then
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

launch_args=(
  -NookPerfLibrary "$working"
  -NookPerfScript "$(cd "$(dirname "$script_arg")" && pwd)/$(basename "$script_arg")"
  -NookPerfLabel "$label"
  -NookStallMs 50
  -autoRefreshEnabled NO
  -NookFaviconFetch NO
  -NookAICategorize NO
  -NookFreezeRelativeTime
)

started_epoch="$(date +%s)"
if [[ -n "$xctrace_template" ]]; then
  trace="$run_dir/$lib_name-$script_name-$variant-$(date +%Y%m%d-%H%M%S).trace"
  xcrun xctrace record --template "$xctrace_template" --output "$trace" --launch -- "$executable" "${launch_args[@]}"
else
  open -n -W "$app" --args "${launch_args[@]}"
fi

log_path=""
while IFS= read -r candidate; do
  begin="$(grep 'run\.begin' "$candidate" 2>/dev/null | grep "label=$label" | tail -1 || true)"
  [[ -n "$begin" ]] || continue
  declared="$(printf '%s\n' "$begin" | sed -n 's/.* log=\([^ ]*\).*/\1/p')"
  if [[ -n "$declared" && -f "$declared" ]]; then
    log_path="$declared"
    break
  fi
  modified="$(stat -f %m "$candidate" 2>/dev/null || echo 0)"
  if [[ "$modified" -ge "$started_epoch" ]]; then log_path="$candidate"; fi
done < <(find "$HOME/Library/Containers" "${TMPDIR:-/tmp}" -type f -name ui-forensics.log -print 2>/dev/null)

[[ -n "$log_path" && -f "$log_path" ]] || {
  echo "could not locate ui-forensics.log for label=$label" >&2
  exit 1
}

n=1
while [[ -e "$run_dir/$lib_name-$script_name-$variant-$n.log" ]]; do n=$((n + 1)); done
destination="$run_dir/$lib_name-$script_name-$variant-$n.log"
mv "$log_path" "$destination"
echo "$destination"
