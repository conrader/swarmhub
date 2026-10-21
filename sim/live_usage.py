#!/usr/bin/env python3
"""Read-only usage snapshots of exactly owned QA sessions before their deletion.

This sidecar does not load auth or send HTTP/model requests. Keep one maximum
counter snapshot per session because cleanup deletes the authoritative row.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import argparse
import json
from pathlib import Path
import sqlite3
import time


def snapshot(db, session_ids):
    if not all(s.startswith("QA-") for s in session_ids):
        raise ValueError("Only exactly registered QA session IDs may be read")
    records = []
    with sqlite3.connect("file:" + str(db) + "?mode=ro", uri=True) as conn:
        conn.row_factory = sqlite3.Row
        for sid in session_ids:
            row = conn.execute("SELECT id, model, api_call_count, tool_call_count, input_tokens, output_tokens, cache_read_tokens, reasoning_tokens FROM sessions WHERE id=?", (sid,)).fetchone()
            if row:
                records.append(dict(row))
    return records


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--results", type=Path, required=True)
    p.add_argument("--db", type=Path, required=True)
    p.add_argument("--seconds", type=int, default=240)
    args = p.parse_args()
    output = args.results.parent / "usage-snapshots.json"
    ledger = json.loads(output.read_text()) if output.exists() else {}
    deadline = time.monotonic() + min(args.seconds, 600)
    while time.monotonic() < deadline:
        try:
            data = json.loads(args.results.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(.25)
            continue
        for row in snapshot(args.db, data.get("owned_sessions", [])):
            previous = ledger.get(row["id"], {})
            if (row.get("api_call_count") or 0) >= (previous.get("api_call_count") or 0):
                ledger[row["id"]] = row
        output.write_text(json.dumps(ledger, indent=2) + "\n")
        if any(t["name"] == "QA-final-health" for t in data["traces"]):
            break
        time.sleep(.25)
    print("QA captured sessions", len(ledger), "model calls", sum(r.get("api_call_count") or 0 for r in ledger.values()))


if __name__ == "__main__":
    main()
