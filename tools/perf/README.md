# Nook performance fixtures and runs

These tools generate isolated, deterministic libraries and drive the DEBUG-only
performance harness. Generated fixtures live under `perf-data/`; captured logs
live under `perf-runs/`. Both paths are ignored by Git. The runner restores a
golden copy before every launch and passes `-NookPerfLibrary`, so it neither
opens the user's real library nor writes its bookmark/UserDefaults.

## Generate golden libraries

Run these commands from the repository root:

```sh
NOOK_GEN_PERF_LIB="$PWD/perf-data/golden/lib-5k" NOOK_GEN_N=5000 \
  swift test --package-path NookKit --filter PerfLibraryGenerator
NOOK_GEN_PERF_LIB="$PWD/perf-data/golden/lib-10k" NOOK_GEN_N=10000 \
  swift test --package-path NookKit --filter PerfLibraryGenerator
NOOK_GEN_PERF_LIB="$PWD/perf-data/golden/lib-20k" NOOK_GEN_N=20000 \
  swift test --package-path NookKit --filter PerfLibraryGenerator
```

Each invocation also rewrites `perf-data/feeds/<lib>/{none,trickle,burst,big1}`,
so every library has its own feed XML. Each feed serves only its newest 30
items plus the variant's additions, like a real rolling feed. Article ids are
`<feedID>#<guid>`, the shape `RSSFeedService`/`ReaderStore` produce on refresh,
so `none` yields zero new articles; the always-on test
`fixture ids match refreshed article ids` parses the XML with the real parser
to keep it that way. Running the same command twice produces byte-identical
fixture contents.

`Nook/Info.plist` currently has `NSAppTransportSecurity` →
`NSAllowsArbitraryLoads=true`, so the cleartext `http://127.0.0.1:8765` feed
server needs no additional ATS exception. If that broad permission is removed,
add a localhost development exception before using refresh scenarios.

## Run

Build first with `make build`. A single run takes a label (`[A-Za-z0-9._-]`,
no leading dot), library (a generated name or directory), driver JSON, and
optional feed variant. Port 8765 must be free; the runner refuses to start
next to a stale feed server. It passes `-NookPerfSHA` with the current short
HEAD, archives any earlier `ui-forensics.log` (in `$TMPDIR` or the Nook
container's tmp) to `perf-runs/.work/<label>/archived-logs`, and saves the
launch's log as `perf-runs/<label>/<lib>-<script>-<variant>-<n>.log`:

```sh
tools/perf/run.sh before-$(git rev-parse --short HEAD) lib-10k tools/perf/scripts/switch.json none
tools/perf/run.sh after-p2 lib-10k tools/perf/scripts/refresh-trickle.json trickle
```

To capture an Instruments trace, put `--xctrace` first:

```sh
tools/perf/run.sh --xctrace 'Animation Hitches' after-p2 lib-10k tools/perf/scripts/scroll.json none
```

The matrix runner maps the groups to the driver scripts in `tools/perf/scripts`
(set `NOOK_PERF_SCRIPTS=/another/directory` otherwise): A → `switch.json`
(5k/10k/20k), B → `refresh-none.json` (B1), `refresh-trickle.json`
(B2/B3/B5), `refresh-big1.json` (B4), C → `scroll.json` (10k/20k),
D → `toggle.json`, E → `misc.json`. A single legacy `refresh.json` is still
accepted. Refresh-driven steps (all of B, plus C4 and E3 under `trickle`) run
one launch per step and repetition, five each, because the first refresh
consumes the new items and the golden library is restored only per launch.
Derived single-step scripts are written under `perf-runs/.work/<label>/scripts`:

```sh
tools/perf/run-all.sh before-$(git rev-parse --short HEAD)
```

For a real wheel-path check, make Nook frontmost and grant Accessibility access
to the invoking Terminal/shell. `wheel.swift fling` posts phased wheel and
momentum events; `constant` posts a three-second constant-velocity scroll:

```sh
tools/perf/wheel.swift fling
tools/perf/wheel.swift constant
```

## Report and compare

```sh
python3 .claude/skills/ui-behavior-forensics/perfreport.py perf-runs/before-abc1234
python3 .claude/skills/ui-behavior-forensics/perfreport.py --compare before-abc1234 after-p2
python3 .claude/skills/ui-behavior-forensics/perfreport.py perf-runs/after-p2 --trail A1
python3 .claude/skills/ui-behavior-forensics/perfreport.py perf-runs/after-p2 --json
python3 .claude/skills/ui-behavior-forensics/perfreport.py --selftest
```

Records are keyed by scenario, library, and feed variant (from the log file
name). Warm repetitions are summarized as median and worst; the cold rep
(`cold=` on the stats or `scenario.begin` line, else rep 0) is kept separate,
and `ttfr=-1` (no selection in the scenario) is not a sample. `mergeP95` is
read as logged (older builds: `mergeMs`, which was the per-call p95);
`publish/dur` uses `activeDur` when present; `updateInPlaceMs`, `rowcontent`,
and `body` are divided by `toggles=` (or the count from `toggle.json`). `--trail ID` prints each rep's raw
window from `scenario.begin` through `scenario.stats`. Compare output applies
the thresholds from `docs/perf/measurement.md` and calls out every common
lower-is-better metric whose median worsened by more than 10%, including rises
from 0. `droppedPct`, `missedSelection`, and `readerTTFR` feed the C3/D1 thresholds,
which show NO DATA for builds that do not log them.
