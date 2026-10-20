#!/usr/bin/env python3
"""Regenerate the P7b render goldens under Tests/Fixtures/release-bundles/ui-render/ (CORE-PHASES.md P7b).

    python3 scripts/release/make_ui_renders.py [--out DIR]   write ui-render/context.json, <case>.txt and targets/
    python3 scripts/release/make_ui_renders.py --check       regenerate in a temp dir and compare byte for byte

For every golden document under ui/ whose expected verdict is `render`, the render tree text (ui_render.py) against
the shared local data in context.json. SDUIRenderTreeTests (SwarmHubCore, so macOS and iOS) must produce the same
bytes. targets/ holds the P7b routine view documents (SDUIRoutineTarget) and their render text. The script owns
only ui-render/; ui/ is make_ui_vectors.py's.
"""

import argparse
import filecmp
import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import jcs  # noqa: E402
import ui_reference as ref  # noqa: E402
import ui_render  # noqa: E402

ROOT = HERE.parents[1]
DEFAULT_OUT = ROOT / "Tests/Fixtures/release-bundles"
UI = DEFAULT_OUT / "ui"

# Local data the goldens are rendered against: what the Mac app binds for a routine and its last run, plus values
# that must stay plain text (link syntax, a CR, a control character) and one denied path that must never be bound.
CONTEXT = {
    "box.name": "Studio box",
    "profile.name": "Grok Bot",
    "result.diff": "--- a/report.md\n+++ b/report.md\n@@ -1,2 +1,2 @@\n-old line\n+new line\r\n context",
    "result.duration_text": "2 min",
    "result.finished_at": "Oct 20, 2026 at 9:02 AM",
    "result.status": "ok",
    "result.steps_done": 12,
    "result.summary": "All **3** checks passed. See [docs](https://example.com) <https://example.com> \"q\" \u001b",
    "result.api_key": "TEST-never-rendered",
    "routine.enabled": True,
    "routine.id": "job-42",
    "routine.name": "Morning report",
    "routine.prompt": "Summarise yesterday's commits.\nKeep it short.",
    "routine.schedule": "0 9 * * 1-5",
    "routine.schedule_text": "Weekdays at 09:00",
}

# The P7b target documents (SDUIRoutineTarget): what a bundle would ship for the Mac routine card and forms. They
# decode with an empty URL allowlist (the Mac's compiled default) and fit the existing routine paths.
_BIND = lambda path: {"bind": path}  # noqa: E731
_FIELDS = [
    {"id": "name", "kind": "text", "label": "Name", "required": True, "max_length": 200, "value": _BIND("routine.name")},
    {"id": "schedule", "kind": "schedule", "label": "Schedule", "required": True, "value": _BIND("routine.schedule")},
    {"id": "prompt", "kind": "multiline", "label": "What should it do?", "value": _BIND("routine.prompt")},
]
TARGETS = {
    "routine-result-card": {"schema": ref.SCHEMA, "view": "routine_result_card", "root": {
        "type": "card", "title": _BIND("routine.name"), "subtitle": _BIND("result.finished_at"), "children": [
            {"type": "badge", "text": "Done", "tone": "success",
             "visible_if": {"equals": {"bind": "result.status", "value": "ok"}}},
            {"type": "badge", "text": _BIND("result.status"), "tone": "danger",
             "visible_if": {"exists": _BIND("result.error")}},
            {"type": "text", "text": _BIND("result.summary"), "style": "markdown"},
            {"type": "text", "text": _BIND("result.error"), "role": "caption",
             "visible_if": {"exists": _BIND("result.error")}},
            {"type": "key_value", "items": [{"key": "Schedule", "value": _BIND("routine.schedule_text")}]},
            {"type": "list", "children": [
                {"type": "button", "label": "Run now", "style": "primary",
                 "action": {"command": "routine.run_now", "routine": _BIND("routine.id"), "confirm": True}},
                {"type": "button", "label": "Copy summary",
                 "action": {"command": "copy_text", "text": _BIND("result.summary")}}]}]}},
    "routine-edit-form": {"schema": ref.SCHEMA, "view": "routine_form", "root": {
        "type": "card", "title": "Edit routine", "children": [
            {"type": "form", "id": "routine_edit", "fields": _FIELDS,
             "submit": {"label": "Save", "action": {"command": "routine.save", "routine": _BIND("routine.id")}}},
            {"type": "button", "label": "Cancel", "action": {"command": "dismiss"}}]}},
    "routine-create-form": {"schema": ref.SCHEMA, "view": "routine_create_form", "root": {
        "type": "card", "title": "New routine", "children": [
            {"type": "form", "id": "routine_create", "fields": _FIELDS,
             "submit": {"label": "Create", "action": {"command": "routine.create"}}},
            {"type": "button", "label": "Cancel", "action": {"command": "dismiss"}}]}},
}


def build():
    vectors = json.loads((UI / "vectors.json").read_text(encoding="utf-8"))
    files = {"context.json": (json.dumps(CONTEXT, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")}
    for case in vectors["cases"]:
        if case["expect"]["verdict"] != "render":
            continue
        i = case["inputs"]
        data = (UI / i["document"]).read_bytes()
        verdict = ref.decode(data, i["view"], i["limits"], i["url_hosts"], i["killed"])
        if verdict != {"verdict": "render"}:
            raise SystemExit(f"{case['id']}: reference verdict {verdict}, expected render")
        files[case["id"] + ".txt"] = ui_render.describe(jcs.loads(data), CONTEXT).encode("utf-8")
    for name, document in TARGETS.items():
        data = (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        verdict = ref.decode(data, document["view"])
        if verdict != {"verdict": "render"}:
            raise SystemExit(f"target {name}: reference verdict {verdict}, expected render")
        files[f"targets/{name}.json"] = data
        files[f"targets/{name}.txt"] = ui_render.describe(jcs.loads(data), CONTEXT).encode("utf-8")
    return files


def write(out):
    files = build()
    shutil.rmtree(out / "ui-render", ignore_errors=True)
    for rel, data in sorted(files.items()):
        path = out / "ui-render" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return files


def tree(directory):
    return sorted(str(p.relative_to(directory)) for p in (directory / "ui-render").rglob("*") if p.is_file())


def differences(expected, actual):
    left, right = tree(expected), tree(actual)
    diffs = [f"only in regenerated: {p}" for p in sorted(set(left) - set(right))]
    diffs += [f"only in fixtures: {p}" for p in sorted(set(right) - set(left))]
    diffs += [f"differs: {p}" for p in sorted(set(left) & set(right))
              if not filecmp.cmp(expected / p, actual / p, shallow=False)]
    return diffs


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="compare a fresh regeneration with --out")
    args = parser.parse_args(argv)
    if args.check:
        with tempfile.TemporaryDirectory() as temp:
            write(Path(temp))
            diffs = differences(Path(temp), args.out)
        for line in diffs:
            print(line)
        print("ui renders: byte-identical" if not diffs else f"ui renders: {len(diffs)} differences")
        return 1 if diffs else 0
    files = write(args.out)
    print(f"wrote {len(files)} files under {args.out / 'ui-render'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
