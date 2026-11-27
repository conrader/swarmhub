"""Summarize matched baseline/candidate trials. Input is one or more JSONL files."""
import argparse
import json
import statistics
from collections import Counter, defaultdict
from pathlib import Path


def summarize(rows):
    pairs = defaultdict(dict)
    for row in rows:
        key = row["model"], row["case"], row["seed"]
        arm = row["arm"]
        if arm not in ("baseline", "guided") or arm in pairs[key]:
            raise ValueError(f"unknown or duplicate arm for {key}: {arm}")
        pairs[key][arm] = row
    if not pairs or any(len(pair) != 2 for pair in pairs.values()):
        raise ValueError("expected a baseline and guided trial for every model, case and seed")
    if len({r.get("guidance_sha256") for r in rows if r["arm"] == "guided"}) > 1:
        raise ValueError("compare one guidance variant at a time")
    cases = {}
    for model, case in sorted({(r["model"], r["case"]) for r in rows}):
        group = [r for r in rows if r["model"] == model and r["case"] == case]
        cases.setdefault(model, {})[case] = {
            arm: dict(passed=sum(r["passed"] for r in group if r["arm"] == arm),
                      trials=sum(r["arm"] == arm for r in group))
            for arm in ("baseline", "guided")}
    flips = Counter()
    for pair in pairs.values():
        b, g = pair["baseline"]["passed"], pair["guided"]["passed"]
        flips["gain" if g and not b else "loss" if b and not g else "tie"] += 1
    metrics = {}
    for arm in ("baseline", "guided"):
        group = [r for r in rows if r["arm"] == arm]
        metrics[arm] = dict(passed=sum(r["passed"] for r in group), trials=len(group),
                            median_seconds=statistics.median(r["seconds"] for r in group),
                            median_tool_calls=statistics.median(r["tool_calls"] for r in group),
                            timeouts=sum(r["status"] == "timeout" for r in group))
    return dict(cases=cases, paired=dict(flips), metrics=metrics)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", type=Path, nargs="+")
    args = parser.parse_args()
    rows = [json.loads(line) for file in args.files for line in file.read_text().splitlines() if line.strip()]
    print(json.dumps(summarize(rows), indent=2, sort_keys=True))
