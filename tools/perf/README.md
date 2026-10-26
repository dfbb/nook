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

Each invocation also refreshes `perf-data/feeds/{none,trickle,burst,big1}`.
Running the same command twice produces byte-identical fixture contents.

`Nook/Info.plist` currently has `NSAppTransportSecurity` →
`NSAllowsArbitraryLoads=true`, so the cleartext `http://127.0.0.1:8765` feed
server needs no additional ATS exception. If that broad permission is removed,
add a localhost development exception before using refresh scenarios.

## Run

Build first with `make build`. A single run takes a label, library (a generated
name or directory), driver JSON, and optional feed variant:

```sh
tools/perf/run.sh before-$(git rev-parse --short HEAD) lib-10k tools/perf/scripts/A.json none
tools/perf/run.sh after-p2 lib-10k tools/perf/scripts/B.json trickle
```

To capture an Instruments trace, put `--xctrace` first:

```sh
tools/perf/run.sh --xctrace 'Animation Hitches' after-p2 lib-10k tools/perf/scripts/C.json trickle
```

The matrix runner expects `A.json` through `E.json` in `tools/perf/scripts`.
Set `NOOK_PERF_SCRIPTS=/another/directory` when the driver scripts are elsewhere:

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

Warm repetitions are summarized as median and worst; cold repetitions are kept
separate. Compare output applies the thresholds from `docs/perf/measurement.md`
and calls out every common lower-is-better metric whose median worsened by more
than 10%.
