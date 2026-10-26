#!/usr/bin/env python3
"""Summarize Nook scenario.stats records and compare performance runs."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import statistics
import sys
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
    "D.updateInPlaceMs": (16.0, 16.0, "≤16"),
    "D.rowcontentPerToggle": (5.0, 5.0, "≤5"),
    "D.listBodyPerToggle": (1.0, 1.0, "≤1"),
    "D.readerTTFR": (100.0, 100.0, "≤100"),
}
EXCLUSIVE_THRESHOLDS = {"A.worstStall", "B.hitchRatio", "C.hitchRatio", "C.worstFrame"}

TABLE_ROWS = [
    ("A1", "10k", "worstStall", "worstStall ms"),
    ("A1", "10k", "ttfr", "ttfr ms"),
    ("A1", "10k", "publishRows", "publishRows"),
    ("A1", "10k", "rowcontentPerPublish", "rowcontent/publish"),
    ("B2", "10k", "mergeP95", "mergeMs/flush p95"),
    ("B2", "10k", "publishPerDuration", "publish/dur"),
    ("B1", "10k", "mergeChangedNoNew", "changedNoNew"),
    ("B1", "10k", "publish", "publish"),
    ("C1", "10k", "hitchRatio", "hitchRatio ms/s"),
    ("C1", "10k", "worstFrame", "worstFrame ms"),
    ("C5", "20k", "growMaxMs", "growMaxMs"),
    ("C5", "20k", "stalls100", "stalls≥100"),
    ("D2", "10k", "updateInPlaceMs", "toggle ms"),
    ("D2", "10k", "rowcontentPerToggle", "rowcontent/toggle"),
]

SELF_BEFORE = """\
0 run.begin label=before sha=1111111 lib=lib-10k hz=60 log=/tmp/a.log
1 scenario.stats id=A1 rep=0 cold=1 dur=900 stalls50=2 stalls100=1 stalls250=0 worstStall=180 ttfr=330 publish=1 publishRows=10000 rowcontent=10000 applyMs=8
2 scenario.stats id=A1 rep=1 cold=0 dur=800 stalls50=1 stalls100=1 stalls250=0 worstStall=160 ttfr=300 publish=1 publishRows=10000 rowcontent=10000 applyMs=7
3 scenario.stats id=A1 rep=2 cold=0 dur=700 stalls50=1 stalls100=1 stalls250=0 worstStall=140 ttfr=280 publish=1 publishRows=10000 rowcontent=10000 applyMs=6
4 scenario.stats id=C1 rep=1 cold=0 dur=1000 stalls100=1 stalls250=0 hitchRatio=12 worstFrame=140 growMaxMs=12
"""
SELF_AFTER = """\
0 run.begin label=after sha=2222222 lib=lib-10k hz=60 log=/tmp/b.log
1 scenario.stats id=A1 rep=0 cold=1 dur=300 stalls50=0 stalls100=0 stalls250=0 worstStall=80 ttfr=220 publish=1 publishRows=200 rowcontent=300 applyMs=1
2 scenario.stats id=A1 rep=1 cold=0 dur=200 stalls50=0 stalls100=0 stalls250=0 worstStall=70 ttfr=120 publish=1 publishRows=200 rowcontent=300 applyMs=1
3 scenario.stats id=A1 rep=2 cold=0 dur=180 stalls50=0 stalls100=0 stalls250=0 worstStall=60 ttfr=110 publish=1 publishRows=200 rowcontent=280 applyMs=.8
4 scenario.stats id=C1 rep=1 cold=0 dur=1000 stalls100=0 stalls250=0 hitchRatio=3 worstFrame=70 growMaxMs=4
"""


@dataclass
class Record:
    scenario: str
    library: str
    cold: bool
    values: dict[str, float]
    raw: str
    path: str


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


def derived(values: dict[str, float]) -> None:
    publish = values.get("publish", 0)
    duration = values.get("dur", 0)
    flushes = values.get("mergeFlush", 0)
    toggles = values.get("toggles", 20)
    if publish:
        values["rowcontentPerPublish"] = values.get("rowcontent", 0) / publish
    if duration:
        values["publishPerDuration"] = publish / max(1, math.ceil(duration / 1500) + 1)
    if "mergeP95" not in values and flushes:
        values["mergeP95"] = values.get("mergeMs", 0) / flushes
        values["mergeFallbackRatio"] = values.get("mergeFallback", 0) / flushes
    if toggles:
        values["rowcontentPerToggle"] = values.get("rowcontent", 0) / toggles
        values["listBodyPerToggle"] = values.get("body", 0) / toggles
        values["updateInPlaceMs"] = values.get("updateInPlaceMs", values.get("updateInPlace", 0) / toggles)


def parse_text(text: str, path: str = "<sample>") -> tuple[list[Record], list[str]]:
    records: list[Record] = []
    beginnings: list[str] = []
    library = "unknown"
    for raw in text.splitlines():
        begin = BEGIN.search(raw)
        if begin:
            beginnings.append(raw)
            library = normalize_library(fields(begin["fields"]).get("lib", library))
        match = STATS.search(raw)
        if not match:
            continue
        parsed = fields(match["fields"])
        scenario = parsed.get("id")
        if not scenario:
            continue
        values = {key: parsed_value for key, value in parsed.items() if (parsed_value := number(value)) is not None}
        derived(values)
        records.append(Record(scenario, library, parsed.get("cold") == "1", values, raw, path))
    return records, beginnings


def load(path: pathlib.Path) -> tuple[list[Record], list[str]]:
    files = sorted(path.rglob("*.log")) if path.is_dir() else [path]
    records: list[Record] = []
    beginnings: list[str] = []
    for file in files:
        parsed, runs = parse_text(file.read_text(errors="replace"), str(file))
        records.extend(parsed)
        beginnings.extend(runs)
    return records, beginnings


def summarize(records: list[Record]) -> dict[str, dict[str, dict[str, dict[str, float]]]]:
    grouped: dict[tuple[str, str, bool], list[Record]] = defaultdict(list)
    for record in records:
        grouped[(record.scenario, record.library, record.cold)].append(record)
    result: dict[str, dict[str, dict[str, dict[str, float]]]] = defaultdict(lambda: defaultdict(dict))
    for (scenario, library, cold), rows in sorted(grouped.items()):
        metric_names = sorted(set().union(*(row.values.keys() for row in rows)))
        metrics = {}
        for metric in metric_names:
            samples = [row.values[metric] for row in rows if metric in row.values]
            metrics[metric] = {"median": statistics.median(samples), "worst": max(samples), "n": len(samples)}
        result[scenario][library]["cold" if cold else "warm"] = metrics
    return result


def fmt(value: float | None) -> str:
    if value is None:
        return "–"
    return f"{value:.2f}".rstrip("0").rstrip(".")


def metric(summary: dict, scenario: str, library: str, name: str) -> dict[str, float] | None:
    return summary.get(scenario, {}).get(library, {}).get("warm", {}).get(name)


def threshold_for(scenario: str, library: str, name: str) -> tuple[float | None, float | None, str] | None:
    if library == "20k":
        return (0, 0, "stalls≥250 = 0") if name == "stalls250" else None
    if scenario == "B1" and name == "publish":
        return (0, 0, "0")
    return THRESHOLDS.get(f"{scenario[0]}.{name}")


def verdict(scenario: str, library: str, name: str, stats: dict[str, float] | None) -> tuple[str, str]:
    threshold = threshold_for(scenario, library, name)
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


def compare(before: dict, after: dict, before_runs: list[str], after_runs: list[str]) -> str:
    lines = [
        "| ID | lib | 지표 | before (med / worst) | after (med / worst) | Δ med | 기준 | 판정 |",
        "|---|---|---|---:|---:|---:|---|---|",
    ]
    for scenario, library, name, display in TABLE_ROWS:
        old = metric(before, scenario, library, name)
        new = metric(after, scenario, library, name)
        delta = None
        regression = False
        if old and new and old["median"] != 0:
            delta = (new["median"] - old["median"]) / old["median"] * 100
            regression = delta > 10
        threshold, status = verdict(scenario, library, name, new)
        if regression:
            status = (status + "; REGRESSION >10%").strip("; ")
        old_text = "–" if not old else f"{fmt(old['median'])} / {fmt(old['worst'])}"
        new_text = "–" if not new else f"{fmt(new['median'])} / {fmt(new['worst'])}"
        delta_text = "–" if delta is None else f"{delta:+.1f}%"
        lines.append(f"| {scenario} | {library} | {display} | {old_text} | {new_text} | {delta_text} | {threshold} | {status} |")

    # Flag every common, lower-is-better metric that regressed, not only rows above.
    known = {(row[0], row[1], row[2]) for row in TABLE_ROWS}
    regressions = []
    for scenario in sorted(set(before) & set(after)):
        for library in sorted(set(before[scenario]) & set(after[scenario])):
            old_metrics = before[scenario][library].get("warm", {})
            new_metrics = after[scenario][library].get("warm", {})
            for name in sorted(set(old_metrics) & set(new_metrics)):
                if (scenario, library, name) in known or name in {"frames", "rep", "cold"}:
                    continue
                old_median = old_metrics[name]["median"]
                new_median = new_metrics[name]["median"]
                if old_median > 0 and new_median > old_median * 1.10:
                    regressions.append(f"{scenario}/{library} {name}: {old_median:g} → {new_median:g}")
    if regressions:
        lines.extend(["", "10% 초과 악화: " + "; ".join(regressions)])
    cold_rows = []
    for scenario in sorted(set(before) | set(after)):
        for library in sorted(set(before.get(scenario, {})) | set(after.get(scenario, {}))):
            old = before.get(scenario, {}).get(library, {}).get("cold", {}).get("ttfr")
            new = after.get(scenario, {}).get(library, {}).get("cold", {}).get("ttfr")
            if old or new:
                cold_pass = "NO DATA" if not new else ("PASS" if new["worst"] <= 400 else "FAIL")
                cold_rows.append(
                    f"{scenario}/{library} cold ttfr: "
                    f"{fmt(old['median']) if old else '–'} / {fmt(old['worst']) if old else '–'} → "
                    f"{fmt(new['median']) if new else '–'} / {fmt(new['worst']) if new else '–'} "
                    f"(≤400, {cold_pass})"
                )
    if cold_rows:
        lines.extend(["", "Cold reps: " + "; ".join(cold_rows)])
    lines.extend(["", f"Runs: before={len(before_runs)}, after={len(after_runs)}"])
    if before_runs: lines.append("before: `" + before_runs[-1] + "`")
    if after_runs: lines.append("after: `" + after_runs[-1] + "`")
    return "\n".join(lines)


def print_summary(summary: dict) -> None:
    for scenario in sorted(summary):
        for library in sorted(summary[scenario]):
            for kind in ("warm", "cold"):
                metrics = summary[scenario][library].get(kind)
                if not metrics:
                    continue
                print(f"{scenario} {library} {kind}")
                for name, values in sorted(metrics.items()):
                    print(f"  {name:24} med={fmt(values['median']):>8} worst={fmt(values['worst']):>8} n={int(values['n'])}")


def selftest() -> None:
    before_records, before_runs = parse_text(SELF_BEFORE)
    after_records, after_runs = parse_text(SELF_AFTER)
    before = summarize(before_records)
    after = summarize(after_records)
    assert metric(after, "A1", "10k", "ttfr")["median"] == 115
    report = compare(before, after, before_runs, after_runs)
    assert "| A1 | 10k | ttfr ms" in report
    assert "PASS" in report
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
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if args.compare:
        before_records, before_runs = load(resolve(args.compare[0]))
        after_records, after_runs = load(resolve(args.compare[1]))
        before, after = summarize(before_records), summarize(after_records)
        if args.json:
            print(json.dumps({"before": before, "after": after}, indent=2, sort_keys=True))
        else:
            print(compare(before, after, before_runs, after_runs))
        return
    if not args.path:
        parser.error("path is required unless --compare or --selftest is used")
    records, runs = load(resolve(args.path))
    if args.trail:
        matches = [record.raw for record in records if record.scenario == args.trail]
        if not matches:
            sys.exit(f"no scenario.stats lines for {args.trail}")
        print("\n".join(matches))
        return
    summary = summarize(records)
    if args.json:
        print(json.dumps({"runs": runs, "scenarios": summary}, indent=2, sort_keys=True))
    else:
        print_summary(summary)


if __name__ == "__main__":
    main()
