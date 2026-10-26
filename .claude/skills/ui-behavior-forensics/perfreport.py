#!/usr/bin/env python3
"""Summarize Nook scenario.stats records and compare performance runs."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import statistics
import subprocess
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass

STATS = re.compile(r"\bscenario\.stats\s+(?P<fields>.*)$")
BEGIN = re.compile(r"\brun\.begin\s+(?P<fields>.*)$")
FIELD = re.compile(r"(?P<key>[A-Za-z][A-Za-z0-9_.]*)=(?P<value>\S+)")

# Machine-readable threshold contract from measurement.md §5. Operators receive
# (median, worst, row); None means that dimension is not constrained.
THRESHOLDS = {
    "A.worstStall": (None, 100.0, "<100"),
    "A.stalls250": (0.0, 0.0, "0"),
    "A.ttfr": (150.0, 250.0, "≤150 / ≤250"),
    "A.publish": (2.0, 2.0, "≤2"),
    "A.publishRows": (200.0, 200.0, "≤max(200, selection+50)"),
    "A.rowcontentPerPublish": (400.0, 400.0, "≤2×window (≈400)"),
    "A.applyMs": (2.0, 2.0, "≤2"),
    "B.stalls250": (0.0, 0.0, "0"),
    "B.stalls100": (1.0, 1.0, "≤1"),
    "B.mergeP95": (5.0, 5.0, "≤5"),
    "B.publishPerDuration": (1.0, 1.0, "≤ceil(dur/1.5s)+1"),
    "B.mergeChangedNoNew": (0.0, 0.0, "0 (B1)"),
    "B.mergeFallbackRatio": (0.10, 0.10, "≤10%"),
    "B.hitchRatio": (5.0, 5.0, "<5"),
    "C.hitchRatio": (5.0, 5.0, "<5"),
    "C.worstFrame": (100.0, 100.0, "<100"),
    "C.stalls100": (0.0, 0.0, "0"),
    "C.growMaxMs": (8.0, 8.0, "≤8"),
    "C.droppedPercent": (2.0, 2.0, "≤2%"),
    "C.missedSelection": (0.0, 0.0, "0"),
    "D.updateInPlaceMs": (16.0, 16.0, "max ≤16"),
    "D.rowcontentPerToggle": (5.0, 5.0, "≤5"),
    "D.listBodyPerToggle": (1.0, 1.0, "≤1"),
    "D.readerTTFR": (100.0, 100.0, "≤100"),
}
EXCLUSIVE_THRESHOLDS = {"A.worstStall", "B.hitchRatio", "C.hitchRatio", "C.worstFrame"}

# (scenario, lib, variant, metric, label). The variant is the feed variant the
# step is measured under (run-all.sh); it is part of the record key so B1/none
# never mixes with B1/trickle.
TABLE_ROWS = [
    ("A1", "10k", "none", "worstStall", "worstStall ms"),
    ("A1", "10k", "none", "ttfr", "ttfr ms"),
    ("A1", "10k", "none", "publishRows", "publishRows"),
    ("A1", "10k", "none", "rowcontentPerPublish", "rowcontent/publish"),
    ("B2", "10k", "trickle", "mergeP95", "mergeMs p95"),
    ("B2", "10k", "trickle", "publishPerDuration", "publish/dur"),
    ("B1", "10k", "none", "mergeChangedNoNew", "changedNoNew"),
    ("B1", "10k", "none", "publish", "publish"),
    ("C1", "10k", "none", "hitchRatio", "hitchRatio ms/s"),
    ("C1", "10k", "none", "worstFrame", "worstFrame ms"),
    ("C3", "10k", "none", "droppedPercent", "dropped %"),
    ("C3", "10k", "none", "missedSelection", "missed selection"),
    ("C5", "20k", "none", "growMaxMs", "growMaxMs"),
    ("C5", "20k", "none", "stalls100", "stalls≥100"),
    ("D1", "10k", "none", "readerTTFR", "reader ttfr ms"),
    ("D2", "10k", "none", "updateInPlaceMs", "toggle max ms"),
    ("D2", "10k", "none", "rowcontentPerToggle", "rowcontent/toggle"),
]

# Toggle counts per scenario from tools/perf/scripts/toggle.json. P0-A reports
# updateInPlaceMs/rowcontent/body as scenario totals; a `toggles=` stats key wins.
TOGGLE_COUNTS = {"D2": 20, "D3": 20, "D4": 1, "D5": 20}
VARIANTS = ("none", "trickle", "burst", "big1")
LOG_NAME = re.compile(r"-(?P<variant>none|trickle|burst|big1)-\d+\.log$")
SCENARIO_BEGIN = re.compile(r"\bscenario\.begin\s+(?P<fields>.*)$")
NON_METRICS = {"frames", "rep", "cold", "toggles", "dur", "activeDur", "sel"}
# measurement.md §4: a run (driver.error) or rep (timeouts) that logged one of
# these is invalid. PerfDriver logs settle.timeout before the rep's
# scenario.begin and quiesce.timeout before its stats, both with id=; the
# list's perf.frame.timeout carries no id and taints the next stats record.
INVALID_FILE = re.compile(r"\bperf\.driver\.error\b")
INVALID_REP = re.compile(r"\bperf\.(?P<kind>quiesce|settle|frame)\.timeout\b(?P<fields>.*)$")

SELF_BEFORE = """\
0 run.begin label=before sha=1111111 lib=lib-10k hz=60 log=/tmp/a.log
1 scenario.begin         id=A1 rep=0 cold=1
1.1 STALL                  for 0.9s during list.publish
2 scenario.stats id=A1 rep=0 dur=900 stalls50=2 stalls100=1 stalls250=0 worstStall=180 ttfr=900 publish=1 publishRows=10000 rowcontent=10000 applyMs=8
3 scenario.begin         id=A1 rep=1 cold=0
3.1 list.publish           rows=30->10000 animated=false
4 scenario.stats id=A1 rep=1 dur=800 stalls50=1 stalls100=1 stalls250=0 worstStall=160 ttfr=300 publish=1 publishRows=10000 rowcontent=10000 applyMs=7
5 scenario.begin         id=A1 rep=2 cold=0
6 scenario.stats id=A1 rep=2 dur=700 stalls50=1 stalls100=1 stalls250=0 worstStall=140 ttfr=280 publish=1 publishRows=10000 rowcontent=10000 applyMs=6
7 scenario.begin         id=C1 rep=1 cold=0
8 scenario.stats id=C1 rep=1 dur=1000 stalls100=1 stalls250=0 hitchRatio=12 worstFrame=140 growMaxMs=12 stalledMs=0
9 scenario.begin         id=D2 rep=1 cold=0
10 scenario.stats id=D2 rep=1 dur=10000 updateInPlaceMs=400 rowcontent=2000 body=40
"""
SELF_AFTER = """\
0 run.begin label=after sha=2222222 lib=lib-10k hz=60 log=/tmp/b.log
1 scenario.begin         id=A1 rep=0 cold=1
2 scenario.stats id=A1 rep=0 dur=300 stalls50=0 stalls100=0 stalls250=0 worstStall=80 ttfr=900 publish=1 publishRows=200 rowcontent=300 applyMs=1
3 scenario.begin         id=A1 rep=1 cold=0
3.1 list.publish           rows=30->200 animated=false
3.2 list.settled           sinceSelect=120ms
4 scenario.stats id=A1 rep=1 dur=200 stalls50=0 stalls100=0 stalls250=0 worstStall=70 ttfr=120 publish=1 publishRows=200 rowcontent=300 applyMs=1
5 scenario.begin         id=A1 rep=2 cold=0
6 scenario.stats id=A1 rep=2 dur=180 stalls50=0 stalls100=0 stalls250=0 worstStall=60 ttfr=110 publish=1 publishRows=200 rowcontent=280 applyMs=.8
7 scenario.begin         id=C1 rep=1 cold=0
8 scenario.stats id=C1 rep=1 dur=1000 stalls100=0 stalls250=0 hitchRatio=3 worstFrame=70 growMaxMs=4 stalledMs=40
9 scenario.begin         id=D2 rep=1 cold=0
10 scenario.stats id=D2 rep=1 dur=10000 updateInPlaceMs=40 rowcontent=60 body=20
11 scenario.begin         id=C3 rep=1 cold=0
12 scenario.stats id=C3 rep=1 dur=5000 frames=297 dropped=3
"""
# The follow-up P0-A contract: cold/toggles/mergeP95/activeDur/droppedPct/
# readerTTFR/missedSelection on stats, mergeMs as a total, ttfr=-1 for no select.
SELF_NEXT = """\
0 run.begin label=next sha=3333333 lib=lib-10k hz=60 log=/tmp/c.log
1 scenario.stats id=A1 rep=0 cold=1 ttfr=300 dur=500
2 scenario.stats id=A1 rep=1 cold=0 ttfr=100 dur=500
3 scenario.stats id=B2 rep=1 cold=0 dur=9000 activeDur=3000 publish=3 mergeMs=40 mergeP95=4 mergeFlush=0 mergeFallback=0 ttfr=-1
4 scenario.stats id=D2 rep=1 cold=0 toggles=10 updateInPlaceMs=50 updateInPlaceMaxMs=9 rowcontent=30 body=10 ttfr=-1
5 scenario.stats id=D1 rep=1 cold=0 readerTTFR=80 ttfr=-1
6 scenario.stats id=C3 rep=1 cold=0 droppedPct=1.5 dropped=99 frames=1 missedSelection=0
"""
SELF_REFRESH_NONE = """\
0 run.begin label=after sha=2222222 lib=lib-10k hz=60 log=/tmp/b.log
1 scenario.begin         id=B1 rep=1 cold=0
2 scenario.stats id=B1 rep=1 dur=3000 publish=0 mergeMs=0 mergeFlush=0 mergeChangedNoNew=0
"""
SELF_REFRESH_TRICKLE = """\
0 run.begin label=after sha=2222222 lib=lib-10k hz=60 log=/tmp/b.log
1 scenario.begin         id=B1 rep=1 cold=0
2 scenario.stats id=B1 rep=1 dur=3000 publish=3 mergeMs=0 mergeFlush=0 mergeChangedNoNew=30
3 scenario.begin         id=B2 rep=1 cold=0
4 scenario.stats id=B2 rep=1 dur=3000 publish=3 mergeMs=3 mergeFlush=10 mergeFallback=1
"""
# measurement.md §4 invalid markers: quiesce (inside the window) and settle
# (before the next rep's scenario.begin) carry id=; frame.timeout does not.
SELF_INVALID = """\
0 run.begin label=after sha=2222222 lib=lib-10k hz=60 log=/tmp/b.log
1 scenario.begin         id=A1 rep=1 cold=0
2 scenario.stats id=A1 rep=1 cold=0 worstStall=50 ttfr=100
3 scenario.begin         id=A1 rep=2 cold=0
3.5 perf.quiesce.timeout   id=A1
4 scenario.stats id=A1 rep=2 cold=0 worstStall=900 ttfr=900
4.5 perf.settle.timeout    id=A1
5 scenario.begin         id=A1 rep=3 cold=0
6 scenario.stats id=A1 rep=3 cold=0 worstStall=800 ttfr=800
7 scenario.begin         id=A1 rep=4 cold=0
8 scenario.stats id=A1 rep=4 cold=0 worstStall=60 ttfr=120
9 scenario.begin         id=C1 rep=1 cold=0
9.5 perf.frame.timeout
10 scenario.stats id=C1 rep=1 cold=0 worstFrame=700
11 scenario.begin         id=C1 rep=2 cold=0
12 scenario.stats id=C1 rep=2 cold=0 worstFrame=40
"""
SELF_DRIVER_ERROR = """\
0 run.begin label=after sha=2222222 lib=lib-10k hz=60 log=/tmp/b.log
1 scenario.stats id=A2 rep=1 cold=0 worstStall=10
2 perf.driver.error      feed=nope reason=not_found
3 scenario.stats id=A2 rep=2 cold=0 worstStall=20
"""
# One FAIL per §5 gate the comparison table does not show, plus passing
# neighbours that must stay out of the gate-failure list.
SELF_GATES = {
    "perf-runs/g/lib-10k-switch-none-1.log": """\
0 run.begin lib=lib-10k
1 scenario.stats id=A10 rep=1 cold=0 worstStall=400 stalls250=1 ttfr=300 publish=3 applyMs=5
2 scenario.stats id=A2 rep=1 cold=0 worstStall=40 stalls250=0 ttfr=90 publish=1 applyMs=1
""",
    "perf-runs/g/lib-10k-refresh-B2-trickle-1.log": """\
0 run.begin lib=lib-10k
1 scenario.stats id=B2 rep=1 cold=0 dur=3000 stalls250=1 stalls100=2 mergeFlush=10 mergeFallback=3 hitchRatio=7 mergeChangedNoNew=4 publish=2
""",
    "perf-runs/g/lib-10k-scroll-none-1.log": """\
0 run.begin lib=lib-10k
1 scenario.stats id=C2 rep=1 cold=0 stalls100=1 hitchRatio=3
""",
    "perf-runs/g/lib-10k-toggle-none-1.log": """\
0 run.begin lib=lib-10k
1 scenario.stats id=D1 rep=1 cold=0 stalls100=1 readerTTFR=80
2 scenario.stats id=D2 rep=1 cold=0 toggles=20 body=40 rowcontent=60
3 scenario.stats id=D5 rep=1 cold=0 toggles=20 hlcTick=40
""",
    "perf-runs/g/lib-20k-refresh-B1-none-1.log": """\
0 run.begin lib=lib-20k
1 scenario.stats id=B1 rep=1 cold=0 stalls250=1 stalls100=3 mergeChangedNoNew=9 publish=4
""",
}

# Scope regressions from review round 4. These values exceed a nearby gate but
# belong to a library/step where measurement.md does not set that gate.
SELF_GATE_SCOPE = {
    "perf-runs/g/lib-5k-switch-none-1.log": """\
0 run.begin lib=lib-5k
1 scenario.stats id=A2 rep=1 cold=0 worstStall=150
""",
    "perf-runs/g/lib-20k-scroll-none-1.log": """\
0 run.begin lib=lib-20k
1 scenario.stats id=C1 rep=1 cold=0 hitchRatio=7
""",
    "perf-runs/g/lib-10k-switch-none-2.log": """\
0 run.begin lib=lib-10k
1 scenario.stats id=A14 rep=1 cold=0 publishRows=549 publish=1 rowcontent=1098
""",
    "perf-runs/g/lib-10k-toggle-none-2.log": """\
0 run.begin lib=lib-10k
1 scenario.stats id=D5 rep=1 cold=0 readerTTFR=300
""",
}


@dataclass
class Record:
    scenario: str
    library: str
    variant: str
    cold: bool
    values: dict[str, float]
    raw: str
    path: str
    window: list[str]
    invalid: str = ""


def fields(text: str) -> dict[str, str]:
    return {match["key"]: match["value"] for match in FIELD.finditer(text)}


def number(value: str) -> float | None:
    try:
        return float(value.rstrip("ms"))
    except ValueError:
        return None


def normalize_library(value: str) -> str:
    match = re.search(r"(?:lib-)?(5k|10k|20k)", value)
    return match.group(1) if match else value


def variant_for(path: str, begin: dict[str, str]) -> str:
    if begin.get("variant") in VARIANTS:
        return begin["variant"]
    match = LOG_NAME.search(path)
    return match["variant"] if match else "-"


def derived(scenario: str, values: dict[str, float]) -> None:
    # ttfr=-1 marks a scenario with no selection; it is not a sample.
    for name in ("ttfr", "readerTTFR"):
        if values.get(name, 0) < 0:
            del values[name]
    publish = values.get("publish", 0)
    duration = values.get("activeDur", values.get("dur", 0))
    if publish:
        values["rowcontentPerPublish"] = values.get("rowcontent", 0) / publish
    if duration:
        values["publishPerDuration"] = publish / max(1, math.ceil(duration / 1500) + 1)
    # Newer builds log mergeP95 (per call) beside a mergeMs total; 885c161
    # logged only mergeMs, which was already the per-call p95.
    if "mergeP95" not in values and "mergeMs" in values:
        values["mergeP95"] = values["mergeMs"]
    if "mergeFlush" in values:
        flushes = values["mergeFlush"]
        values["mergeFallbackRatio"] = values.get("mergeFallback", 0) / flushes if flushes else 0.0
    # updateInPlaceMs/rowcontent/body are scenario totals. Report the mean for
    # diagnostics, but gate updateInPlaceMs on the logged worst individual
    # toggle when available: one 40 ms toggle must not hide in a fast mean.
    toggles = values["toggles"] if "toggles" in values else TOGGLE_COUNTS.get(scenario)
    if toggles:
        values["rowcontentPerToggle"] = values.get("rowcontent", 0) / toggles
        values["listBodyPerToggle"] = values.get("body", 0) / toggles
        if "hlcTick" in values:
            values["hlcTickPerToggle"] = values["hlcTick"] / toggles
        if "updateInPlaceMs" in values:
            values["updateInPlaceTotalMs"] = values["updateInPlaceMs"]
            values["updateInPlaceMeanMs"] = values["updateInPlaceMs"] / toggles
            values["updateInPlaceMs"] = values.get("updateInPlaceMaxMs", values["updateInPlaceMeanMs"])
    if "droppedPercent" not in values:
        if "droppedPct" in values:
            values["droppedPercent"] = values["droppedPct"]
        elif "dropped" in values and values.get("frames", 0) + values["dropped"] > 0:
            values["droppedPercent"] = values["dropped"] / (values.get("frames", 0) + values["dropped"]) * 100
    # Older builds lack these signals; derive them when the raw counts exist so
    # the C3/D1 thresholds report NO DATA instead of silently never applying.
    if "missedSelection" not in values and "keysSent" in values and "selectionMoves" in values:
        values["missedSelection"] = max(0.0, values["keysSent"] - values["selectionMoves"])
    if "readerTTFR" not in values and "readerMs" in values:
        values["readerTTFR"] = values["readerMs"]


def parse_text(text: str, path: str = "<sample>") -> tuple[list[Record], list[str]]:
    records: list[Record] = []
    beginnings: list[str] = []
    library = "unknown"
    variant = variant_for(path, {})
    begun: dict[str, dict[str, str]] = {}
    window: list[str] = []
    file_error = next((raw.strip() for raw in text.splitlines() if INVALID_FILE.search(raw)), "")
    tainted_ids: dict[str, str] = {}
    tainted_next = ""
    for raw in text.splitlines():
        timeout = INVALID_REP.search(raw)
        if timeout:
            timeout_id = fields(timeout["fields"]).get("id")
            if timeout_id:
                tainted_ids.setdefault(timeout_id, f"perf.{timeout['kind']}.timeout")
            else:
                tainted_next = tainted_next or f"perf.{timeout['kind']}.timeout"
        begin = BEGIN.search(raw)
        if begin:
            beginnings.append(raw)
            run_fields = fields(begin["fields"])
            library = normalize_library(run_fields.get("lib", library))
            variant = variant_for(path, run_fields)
        scenario_begin = SCENARIO_BEGIN.search(raw)
        if scenario_begin:
            parsed_begin = fields(scenario_begin["fields"])
            if "id" in parsed_begin:
                begun[parsed_begin["id"]] = parsed_begin
            window = []
        window.append(raw)
        match = STATS.search(raw)
        if not match:
            continue
        parsed = fields(match["fields"])
        scenario = parsed.get("id")
        if not scenario:
            continue
        # cold= lives on scenario.begin in P0-A; accept it on stats too, and
        # fall back to rep 0, which the driver reserves for the cold rep.
        opened = begun.pop(scenario, {})
        if "cold" in parsed:
            marked_cold = parsed["cold"] == "1"
        elif "cold" in opened and opened.get("rep", parsed.get("rep")) == parsed.get("rep"):
            marked_cold = opened["cold"] == "1"
        else:
            marked_cold = parsed.get("rep") == "0"
        # switch.json marks rep 0 on every A step, but only A1 is the first
        # step after launch. A2–A14 are already warm and must not be reported as
        # cold-launch samples.
        cold = scenario == "A1" and marked_cold
        values = {key: parsed_value for key, value in parsed.items() if (parsed_value := number(value)) is not None}
        derived(scenario, values)
        invalid = ("perf.driver.error" if file_error else "") or tainted_ids.pop(scenario, "") or tainted_next
        tainted_next = ""
        records.append(Record(scenario, library, variant, cold, values, raw, path, window, invalid))
        window = []
    return records, beginnings


def load(path: pathlib.Path) -> tuple[list[Record], list[str]]:
    files = sorted(path.rglob("*.log")) if path.is_dir() else [path]
    records: list[Record] = []
    beginnings: list[str] = []
    for file in files:
        if file.name.startswith("feedserver-"):
            continue
        parsed, runs = parse_text(file.read_text(errors="replace"), str(file))
        records.extend(parsed)
        beginnings.extend(runs)
    return records, beginnings


def summarize(records: list[Record]) -> dict:
    """summary[scenario][lib][variant]["warm"|"cold"][metric] = {median, worst, n}."""
    grouped: dict[tuple[str, str, str, bool], list[Record]] = defaultdict(list)
    for record in records:
        if record.invalid:
            continue
        grouped[(record.scenario, record.library, record.variant, record.cold)].append(record)
    result: dict = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    for (scenario, library, variant, cold), rows in sorted(grouped.items()):
        metric_names = sorted(set().union(*(row.values.keys() for row in rows)))
        metrics = {}
        for metric in metric_names:
            samples = [row.values[metric] for row in rows if metric in row.values]
            metrics[metric] = {"median": statistics.median(samples), "worst": max(samples), "n": len(samples)}
        result[scenario][library][variant]["cold" if cold else "warm"] = metrics
    return result


def dropped(records: list[Record]) -> dict:
    """Invalid reps left out of summarize: counts per reason and per file."""
    reasons: dict[str, int] = defaultdict(int)
    files: set[str] = set()
    for record in records:
        if record.invalid:
            reasons[record.invalid] += 1
            files.add(record.path)
    return {"reps": sum(reasons.values()), "files": len(files), "reasons": dict(sorted(reasons.items()))}


def dropped_text(name: str, counts: dict) -> str:
    detail = ", ".join(f"{reason}×{count}" for reason, count in counts["reasons"].items())
    return f"{name}: dropped {counts['reps']} invalid reps in {counts['files']} files" + (f" ({detail})" if detail else "")


def fmt(value: float | None) -> str:
    if value is None:
        return "–"
    return f"{value:.2f}".rstrip("0").rstrip(".")


def metric(summary: dict, scenario: str, library: str, variant: str, name: str) -> dict[str, float] | None:
    variants = summary.get(scenario, {}).get(library, {})
    # "-" holds logs whose file name carries no variant (not written by run.sh).
    chosen = variants.get(variant) or variants.get("-") or {}
    return chosen.get("warm", {}).get(name)


def threshold_for(scenario: str, library: str, name: str, variant: str = "none",
                  selection: dict[str, float] | None = None) -> tuple[float | None, float | None, str] | None:
    if library not in ("10k", "20k"):
        return None
    # 20k enforces stalls≥250 everywhere, A worstStall <250, and the two C5
    # gates called out by the §7 results table. All other §5 gates are 10k-only.
    if library == "20k":
        if name == "stalls250":
            return (0, 0, "stalls≥250 = 0")
        if (scenario[0], name) == ("A", "worstStall"):
            return (None, 250.0, "<250")
        if scenario == "C5" and name in ("growMaxMs", "stalls100"):
            return THRESHOLDS[f"C.{name}"]
        return None
    # A14 selects row 499 before switching. Until stats expose sel=, applying
    # the fixed A1 window would reject the correct selection-preserving window.
    if scenario == "A14" and name in ("publishRows", "rowcontentPerPublish"):
        if not selection:
            return None
        median_window = max(200.0, selection["median"] + 50.0)
        worst_window = max(200.0, selection["worst"] + 50.0)
        scale = 1.0 if name == "publishRows" else 2.0
        median_limit, worst_limit = scale * median_window, scale * worst_window
        return (median_limit, worst_limit,
                f"≤{fmt(worst_limit)} (sel+50 window)" if name == "publishRows"
                else f"≤{fmt(worst_limit)} (2×window)")
    # B1's zero-publish/zero-changed gates assume no new items, i.e. `none`.
    if name in ("publish", "mergeChangedNoNew") and scenario == "B1":
        return ((0, 0, "0") if name == "publish" else THRESHOLDS["B.mergeChangedNoNew"]) if variant in ("none", "-") else None
    if name == "mergeChangedNoNew":
        return None
    if (scenario, name) == ("D1", "stalls100"):
        return (0, 0, "0 (D1)")
    if (scenario, name) == ("D5", "hlcTickPerToggle"):
        return (1, 1, "1 per open (D5)")
    if name == "readerTTFR" and scenario != "D1":
        return None
    return THRESHOLDS.get(f"{scenario[0]}.{name}")


def verdict(scenario: str, library: str, name: str, stats: dict[str, float] | None,
            variant: str = "none", selection: dict[str, float] | None = None) -> tuple[str, str]:
    threshold = threshold_for(scenario, library, name, variant, selection)
    if not threshold:
        return ("–", "–")
    median_limit, worst_limit, label = threshold
    if not stats:
        return (label, "NO DATA")
    key = f"{scenario[0]}.{name}"
    compare_limit = (lambda value, limit: value < limit) if key in EXCLUSIVE_THRESHOLDS else (lambda value, limit: value <= limit)
    passed = ((median_limit is None or compare_limit(stats["median"], median_limit)) and
              (worst_limit is None or compare_limit(stats["worst"], worst_limit)))
    return (label, "PASS" if passed else "FAIL")


def cold_gated(scenario: str, library: str) -> bool:
    """The protocol gates cold ttfr (≤400) on A1/10k only."""
    return (scenario, library) == ("A1", "10k")


def gate_failures(summary: dict) -> list[str]:
    """Every summarized (scenario, lib, variant, metric) a §5 gate covers that FAILs.

    The table above shows a curated subset; this judges all of them, so an A10
    stall or a B2 fallback ratio cannot pass silently. Cold A1 ttfr is ≤400.
    """
    failures = []
    for scenario in sorted(summary):
        for library in sorted(summary[scenario]):
            for variant in sorted(summary[scenario][library]):
                kinds = summary[scenario][library][variant]
                warm = kinds.get("warm", {})
                selection = warm.get("sel")
                for name, stats in sorted(warm.items()):
                    threshold, status = verdict(scenario, library, name, stats, variant, selection)
                    if status == "FAIL":
                        failures.append(f"{scenario}/{library}/{variant} {name}: "
                                        f"{fmt(stats['median'])} / {fmt(stats['worst'])} (기준 {threshold})")
                cold = kinds.get("cold", {}).get("ttfr")
                if cold_gated(scenario, library) and cold and cold["worst"] > 400:
                    failures.append(f"{scenario}/{library}/{variant} cold ttfr: "
                                    f"{fmt(cold['median'])} / {fmt(cold['worst'])} (기준 ≤400)")
    return failures


def gate_section(failures: list[str]) -> list[str]:
    if not failures:
        return ["", "Gate failures: none"]
    return ["", f"Gate failures ({len(failures)}):"] + [f"- {failure}" for failure in failures]


def worsened(old: float, new: float) -> bool:
    """Lower is better for every metric; a rise from 0 counts as a regression."""
    return new > 0 if old == 0 else new > old * 1.10


def compare(before: dict, after: dict, before_runs: list[str], after_runs: list[str],
            drops: tuple[dict, dict] | None = None) -> str:
    lines = [
        "| ID | lib | variant | 지표 | before (med / worst) | after (med / worst) | Δ med | 기준 | 판정 |",
        "|---|---|---|---|---:|---:|---:|---|---|",
    ]
    for scenario, library, variant, name, display in TABLE_ROWS:
        old = metric(before, scenario, library, variant, name)
        new = metric(after, scenario, library, variant, name)
        delta_text = "–"
        regression = False
        if old and new:
            regression = worsened(old["median"], new["median"])
            if old["median"] != 0:
                delta_text = f"{(new['median'] - old['median']) / old['median'] * 100:+.1f}%"
            elif new["median"] != 0:
                delta_text = "0→" + fmt(new["median"])
        threshold, status = verdict(scenario, library, name, new, variant)
        if regression:
            status = (status + "; REGRESSION >10%").strip("; ")
        old_text = "–" if not old else f"{fmt(old['median'])} / {fmt(old['worst'])}"
        new_text = "–" if not new else f"{fmt(new['median'])} / {fmt(new['worst'])}"
        lines.append(f"| {scenario} | {library} | {variant} | {display} | {old_text} | {new_text} | {delta_text} | {threshold} | {status} |")

    # Flag every common, lower-is-better metric that regressed, not only rows above.
    known = {(row[0], row[1], row[2], row[3]) for row in TABLE_ROWS}
    regressions = []
    cold_rows = []
    for scenario in sorted(set(before) | set(after)):
        for library in sorted(set(before.get(scenario, {})) | set(after.get(scenario, {}))):
            old_variants = before.get(scenario, {}).get(library, {})
            new_variants = after.get(scenario, {}).get(library, {})
            for variant in sorted(set(old_variants) | set(new_variants)):
                old_kinds = old_variants.get(variant, {})
                new_kinds = new_variants.get(variant, {})
                old_metrics = old_kinds.get("warm", {})
                new_metrics = new_kinds.get("warm", {})
                for name in sorted(set(old_metrics) & set(new_metrics)):
                    if (scenario, library, variant, name) in known or name in NON_METRICS:
                        continue
                    old_median = old_metrics[name]["median"]
                    new_median = new_metrics[name]["median"]
                    if worsened(old_median, new_median):
                        regressions.append(f"{scenario}/{library}/{variant} {name}: {old_median:g} → {new_median:g}")
                old = old_kinds.get("cold", {}).get("ttfr")
                new = new_kinds.get("cold", {}).get("ttfr")
                if old or new:
                    if not cold_gated(scenario, library):
                        cold_verdict = "–, –"
                    else:
                        cold_verdict = "≤400, " + ("NO DATA" if not new else ("PASS" if new["worst"] <= 400 else "FAIL"))
                    cold_rows.append(
                        f"{scenario}/{library}/{variant} cold ttfr: "
                        f"{fmt(old['median']) if old else '–'} / {fmt(old['worst']) if old else '–'} → "
                        f"{fmt(new['median']) if new else '–'} / {fmt(new['worst']) if new else '–'} "
                        f"({cold_verdict})"
                    )
    if regressions:
        lines.extend(["", "10% 초과 악화: " + "; ".join(regressions)])
    if cold_rows:
        lines.extend(["", "Cold reps: " + "; ".join(cold_rows)])
    lines.extend(gate_section(gate_failures(after)))
    lines.extend(["", f"Runs: before={len(before_runs)}, after={len(after_runs)}"])
    if drops:
        lines.extend([dropped_text("before", drops[0]), dropped_text("after", drops[1])])
    if before_runs: lines.append("before: `" + before_runs[-1] + "`")
    if after_runs: lines.append("after: `" + after_runs[-1] + "`")
    return "\n".join(lines)


def print_summary(summary: dict) -> None:
    for scenario in sorted(summary):
        for library in sorted(summary[scenario]):
            for variant in sorted(summary[scenario][library]):
                for kind in ("warm", "cold"):
                    metrics = summary[scenario][library][variant].get(kind)
                    if not metrics:
                        continue
                    print(f"{scenario} {library} {variant} {kind}")
                    for name, values in sorted(metrics.items()):
                        print(f"  {name:24} med={fmt(values['median']):>8} worst={fmt(values['worst']):>8} n={int(values['n'])}")


def trail(records: list[Record], scenario: str) -> str:
    """Raw log window of each rep: scenario.begin through scenario.stats, verbatim."""
    blocks = [f"--- {record.path}" + (f" (dropped: {record.invalid})" if record.invalid else "") + "\n" + "\n".join(record.window)
              for record in records if record.scenario == scenario]
    return "\n".join(blocks)


def selftest() -> None:
    before_records, before_runs = parse_text(SELF_BEFORE, "perf-runs/before/lib-10k-switch-none-1.log")
    after_records, after_runs = parse_text(SELF_AFTER, "perf-runs/after/lib-10k-switch-none-1.log")
    for text, path in ((SELF_REFRESH_NONE, "perf-runs/after/lib-10k-refresh-B1-none-1.log"),
                       (SELF_REFRESH_TRICKLE, "perf-runs/after/lib-10k-refresh-trickle-1.log")):
        records, runs = parse_text(text, path)
        after_records.extend(records)
        after_runs.extend(runs)
    before = summarize(before_records)
    after = summarize(after_records)

    # Cold: P0-A puts cold=1 only on scenario.begin; the 900ms cold rep must not
    # reach the warm median/worst.
    warm_ttfr = metric(after, "A1", "10k", "none", "ttfr")
    assert warm_ttfr == {"median": 115, "worst": 120, "n": 2}, warm_ttfr
    assert after["A1"]["10k"]["none"]["cold"]["ttfr"]["worst"] == 900
    assert all(r.cold == (r.values["rep"] == 0) for r in after_records if r.scenario == "A1")
    cold_only, _ = parse_text("1 scenario.stats id=A1 rep=0 ttfr=5\n2 scenario.stats id=A1 rep=1 cold=1 ttfr=6")
    assert [r.cold for r in cold_only] == [True, True]

    # Per-toggle: gate on the worst logged toggle, retain totals/means for detail.
    assert metric(after, "D2", "10k", "none", "updateInPlaceMs")["median"] == 2
    assert metric(after, "D2", "10k", "none", "updateInPlaceTotalMs")["median"] == 40
    assert metric(after, "D2", "10k", "none", "updateInPlaceMeanMs")["median"] == 2
    assert metric(after, "D2", "10k", "none", "rowcontentPerToggle")["median"] == 3
    assert metric(after, "D2", "10k", "none", "listBodyPerToggle")["median"] == 1

    # mergeMs is already a p95; only the fallback ratio divides by flushes.
    assert metric(after, "B2", "10k", "trickle", "mergeP95")["median"] == 3
    assert metric(after, "B2", "10k", "trickle", "mergeFallbackRatio")["median"] == 0.1

    # Variant grouping: B1 under none and under trickle stay separate.
    assert metric(after, "B1", "10k", "none", "mergeChangedNoNew")["median"] == 0
    assert metric(after, "B1", "10k", "trickle", "mergeChangedNoNew")["median"] == 30
    assert after["B1"]["10k"]["none"]["warm"]["publish"]["n"] == 1

    # C3 dropped percentage is derived from dropped/(frames+dropped).
    assert metric(after, "C3", "10k", "none", "droppedPercent")["median"] == 1

    # Trail: the whole raw window, including STALL/publish lines, per rep.
    text = trail(before_records, "A1")
    assert "STALL                  for 0.9s" in text and "list.publish           rows=30->10000" in text
    assert text.count("scenario.begin") == 3 and text.count("scenario.stats") == 3

    report = compare(before, after, before_runs, after_runs)
    assert "| A1 | 10k | none | ttfr ms | 290 / 300 | 115 / 120 |" in report, report
    assert "| D2 | 10k | none | toggle max ms | 20 / 20 | 2 / 2 | -90.0% | max ≤16 | PASS |" in report, report
    assert "| B2 | 10k | trickle | mergeMs p95 | – | 3 / 3 | – | ≤5 | PASS |" in report, report
    assert "| B1 | 10k | none | changedNoNew | – | 0 / 0 | – | 0 (B1) | PASS |" in report, report
    assert "| D1 | 10k | none | reader ttfr ms | – | – | – | ≤100 | NO DATA |" in report, report
    assert "| C5 | 20k | none | growMaxMs | – | – | – | ≤8 | NO DATA |" in report, report
    assert threshold_for("A1", "20k", "worstStall")[1] == 250 and threshold_for("A1", "20k", "ttfr") is None
    # Regression from a zero median (stalledMs 0 → 40) is flagged.
    assert "C1/10k/none stalledMs: 0 → 40" in report, report
    assert "A1/10k/none cold ttfr: 900 / 900 → 900 / 900 (≤400, FAIL)" in report, report
    next_records, _ = parse_text(SELF_NEXT, "perf-runs/next/lib-10k-refresh-trickle-B2-trickle-1.log")
    by_id = {(r.scenario, r.cold): r.values for r in next_records}
    assert by_id[("A1", True)]["ttfr"] == 300 and by_id[("A1", False)]["ttfr"] == 100
    assert by_id[("B2", False)]["mergeP95"] == 4 and by_id[("B2", False)]["mergeFallbackRatio"] == 0
    assert by_id[("B2", False)]["publishPerDuration"] == 1  # activeDur 3000 → ceil(2)+1 = 3
    assert "ttfr" not in by_id[("B2", False)]
    assert by_id[("D2", False)]["updateInPlaceMs"] == 9 and by_id[("D2", False)]["updateInPlaceMeanMs"] == 5
    spike_records, _ = parse_text(
        "1 run.begin lib=lib-10k\n2 scenario.stats id=D2 rep=1 toggles=20 updateInPlaceMs=40 updateInPlaceMaxMs=40",
        "perf-runs/next/lib-10k-toggle-none-1.log",
    )
    spike = metric(summarize(spike_records), "D2", "10k", "none", "updateInPlaceMs")
    assert spike == {"median": 40, "worst": 40, "n": 1}
    assert verdict("D2", "10k", "updateInPlaceMs", spike)[1] == "FAIL"
    assert by_id[("D2", False)]["rowcontentPerToggle"] == 3
    assert by_id[("D1", False)]["readerTTFR"] == 80
    assert by_id[("C3", False)]["droppedPercent"] == 1.5 and by_id[("C3", False)]["missedSelection"] == 0
    assert all(r.variant == "trickle" for r in next_records)
    false_cold, _ = parse_text("1 scenario.stats id=A2 rep=0 cold=1 ttfr=50")
    assert len(false_cold) == 1 and not false_cold[0].cold

    # Invalid reps: timeouts drop their rep, driver.error drops the file.
    invalid_records, _ = parse_text(SELF_INVALID, "perf-runs/after/lib-10k-switch-none-2.log")
    error_records, _ = parse_text(SELF_DRIVER_ERROR, "perf-runs/after/lib-10k-switch-none-3.log")
    assert [r.invalid for r in invalid_records] == [
        "", "perf.quiesce.timeout", "perf.settle.timeout", "", "perf.frame.timeout", ""], invalid_records
    assert all(r.invalid == "perf.driver.error" for r in error_records) and len(error_records) == 2
    invalid_summary = summarize(invalid_records + error_records)
    assert metric(invalid_summary, "A1", "10k", "none", "worstStall") == {"median": 55, "worst": 60, "n": 2}
    assert metric(invalid_summary, "C1", "10k", "none", "worstFrame") == {"median": 40, "worst": 40, "n": 1}
    assert "A2" not in invalid_summary
    counts = dropped(invalid_records + error_records)
    assert counts == {"reps": 5, "files": 2, "reasons": {
        "perf.driver.error": 2, "perf.frame.timeout": 1, "perf.quiesce.timeout": 1, "perf.settle.timeout": 1}}, counts
    assert dropped_text("after", counts).startswith("after: dropped 5 invalid reps in 2 files (")
    assert "(dropped: perf.quiesce.timeout)" in trail(invalid_records, "A1")
    dropped_report = compare(before, after, before_runs, after_runs, (dropped(before_records), counts))
    assert "after: dropped 5 invalid reps in 2 files" in dropped_report, dropped_report

    # Every gate: each summarized metric a §5 threshold covers is judged.
    gate_records = [record for path, text in SELF_GATES.items() for record in parse_text(text, path)[0]]
    failures = gate_failures(summarize(gate_records))
    expected = {
        "A10/10k/none worstStall", "A10/10k/none stalls250", "A10/10k/none ttfr",
        "A10/10k/none publish", "A10/10k/none applyMs",
        "B2/10k/trickle stalls250", "B2/10k/trickle stalls100", "B2/10k/trickle mergeFallbackRatio",
        "B2/10k/trickle hitchRatio", "C2/10k/none stalls100", "D1/10k/none stalls100",
        "D2/10k/none listBodyPerToggle", "D5/10k/none hlcTickPerToggle", "B1/20k/none stalls250",
    }
    assert {failure.split(":")[0] for failure in failures} == expected, failures
    # B1's zero-changed gate is a `none` gate only; 20k judges only stalls≥250.
    assert threshold_for("B2", "10k", "mergeChangedNoNew", "trickle") is None
    assert threshold_for("B1", "10k", "mergeChangedNoNew", "trickle") is None
    assert threshold_for("B1", "10k", "publish", "none") == (0, 0, "0")
    gated = compare(summarize([]), summarize(gate_records), [], [])
    assert f"Gate failures ({len(expected)}):" in gated and "- D5/10k/none hlcTickPerToggle: 2 / 2" in gated, gated

    # Gate scope: 5k is reported only; 20k has stalls250, A worstStall, and
    # C5 growMaxMs/stalls100 only. A14's selection-sized window waits for sel=,
    # and readerTTFR is a D1-only gate.
    scope_records = [record for path, text in SELF_GATE_SCOPE.items() for record in parse_text(text, path)[0]]
    assert gate_failures(summarize(scope_records)) == []
    assert threshold_for("A2", "5k", "worstStall") is None
    assert threshold_for("C1", "20k", "hitchRatio") is None
    assert threshold_for("A14", "10k", "publishRows") is None
    assert threshold_for("D5", "10k", "readerTTFR") is None

    scoped_failures, _ = parse_text("""\
0 run.begin lib=lib-20k
1 scenario.stats id=A2 rep=1 cold=0 worstStall=300 stalls250=1
2 scenario.stats id=C5 rep=1 cold=0 growMaxMs=9 stalls100=1
""", "perf-runs/g/lib-20k-mixed-none-1.log")
    assert {failure.split(":")[0] for failure in gate_failures(summarize(scoped_failures))} == {
        "A2/20k/none stalls250", "A2/20k/none worstStall",
        "C5/20k/none growMaxMs", "C5/20k/none stalls100",
    }

    selected_records, _ = parse_text("""\
0 run.begin lib=lib-10k
1 scenario.stats id=A14 rep=1 cold=0 sel=499 publish=1 publishRows=550 rowcontent=1099
""", "perf-runs/g/lib-10k-switch-none-3.log")
    selected_failures = gate_failures(summarize(selected_records))
    assert {failure.split(":")[0] for failure in selected_failures} == {
        "A14/10k/none publishRows", "A14/10k/none rowcontentPerPublish",
    }
    assert "기준 ≤549 (sel+50 window)" in selected_failures[0]

    d1_records, _ = parse_text(
        "0 run.begin lib=lib-10k\n1 scenario.stats id=D1 rep=1 cold=0 readerTTFR=300",
        "perf-runs/g/lib-10k-toggle-none-3.log",
    )
    assert gate_failures(summarize(d1_records))[0].startswith("D1/10k/none readerTTFR:")

    # --strict: exit 1 on any gate failure, 0 without the flag or when all pass.
    with tempfile.TemporaryDirectory() as directory:
        failing = pathlib.Path(directory, "lib-10k-switch-none-1.log")
        failing.write_text(SELF_GATES["perf-runs/g/lib-10k-switch-none-1.log"])
        passing = pathlib.Path(directory, "pass", "lib-10k-switch-none-1.log")
        passing.parent.mkdir()
        passing.write_text("0 run.begin lib=lib-10k\n1 scenario.stats id=A2 rep=1 worstStall=40 ttfr=90\n")
        def exit_code(*argv: str) -> int:
            return subprocess.run([sys.executable, __file__, *argv], capture_output=True).returncode
        assert exit_code(str(failing), "--strict") == 1
        assert exit_code(str(failing)) == 0
        assert exit_code(str(passing), "--strict") == 0
        assert exit_code("--compare", str(passing), str(failing), "--strict") == 1
        # Cold ttfr is gated on A1/10k only; other libs show it without a verdict.
        empty = pathlib.Path(directory, "empty", "lib-10k-switch-none-1.log")
        empty.parent.mkdir()
        empty.write_text("0 run.begin lib=lib-10k\n")
        for library, shown, code in (("20k", "(–, –)", 0), ("10k", "(≤400, FAIL)", 1)):
            cold_log = pathlib.Path(directory, f"cold-{library}", f"lib-{library}-switch-none-1.log")
            cold_log.parent.mkdir()
            cold_log.write_text(f"0 run.begin lib=lib-{library}\n"
                                "1 scenario.stats id=A1 rep=0 cold=1 ttfr=900\n"
                                "2 scenario.stats id=A1 rep=1 cold=0 ttfr=100\n")
            cold_report = compare(summarize([]), summarize(parse_text(cold_log.read_text(), str(cold_log))[0]), [], [])
            assert f"A1/{library}/none cold ttfr: – / – → 900 / 900 {shown}" in cold_report, cold_report
            assert exit_code("--compare", str(empty), str(cold_log), "--strict") == code
        for index, text in enumerate(SELF_GATE_SCOPE.values()):
            scoped = pathlib.Path(directory, f"scope-{index}.log")
            scoped.write_text(text)
            assert exit_code(str(scoped), "--strict") == 0
    print("perfreport selftest: PASS")
    print(report)


def resolve(value: str) -> pathlib.Path:
    direct = pathlib.Path(value)
    return direct if direct.exists() else pathlib.Path("perf-runs") / value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", help="log file or perf-runs/<label> directory")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    parser.add_argument("--trail", metavar="ID")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when any §5 gate fails (the after run with --compare)")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if args.compare:
        before_records, before_runs = load(resolve(args.compare[0]))
        after_records, after_runs = load(resolve(args.compare[1]))
        before, after = summarize(before_records), summarize(after_records)
        drops = (dropped(before_records), dropped(after_records))
        failures = gate_failures(after)
        if args.json:
            print(json.dumps({"before": before, "after": after, "dropped": {"before": drops[0], "after": drops[1]},
                              "gateFailures": failures}, indent=2, sort_keys=True))
        else:
            print(compare(before, after, before_runs, after_runs, drops))
        sys.exit(1 if args.strict and failures else 0)
    if not args.path:
        parser.error("path is required unless --compare or --selftest is used")
    records, runs = load(resolve(args.path))
    if args.trail:
        text = trail(records, args.trail)
        if not text:
            sys.exit(f"no scenario.stats lines for {args.trail}")
        print(text)
        return
    summary = summarize(records)
    failures = gate_failures(summary)
    if args.json:
        print(json.dumps({"runs": runs, "scenarios": summary, "dropped": dropped(records),
                          "gateFailures": failures}, indent=2, sort_keys=True))
    else:
        print_summary(summary)
        print(dropped_text("run", dropped(records)))
        print("\n".join(gate_section(failures)).lstrip("\n"))
    sys.exit(1 if args.strict and failures else 0)


if __name__ == "__main__":
    main()
