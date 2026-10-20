#!/usr/bin/env python3
"""Regenerate the P6a config vectors under Tests/Fixtures/release-bundles/config/ (SCHEMAS.md §12).

    python3 scripts/release/make_config_vectors.py [--out DIR]    write config/ (archives, signed bundle 12, vectors.json,
                                                                  app-config.json)
    python3 scripts/release/make_config_vectors.py --check        regenerate in a temp dir and compare byte for byte

Owns only config/; the P0a vectors (make_vectors.py) stay byte-unchanged. The signed bundle uses the same TEST keys
and key manifest (keys/keys-2.json, signer TEST-release-1). Refuses to write when the reference decoder
(config_reference.py) disagrees with any hand-written expectation in config_vector_cases.py.
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

import app_config_reference  # noqa: E402
import config_reference  # noqa: E402
import ustar  # noqa: E402
import vector_world as vw  # noqa: E402
from app_config_cases import CASES as APP_CASES, expected as app_expected  # noqa: E402
from config_vector_cases import CASES, corrupt_header, doc, r, rep  # noqa: E402

ROOT = HERE.parents[1]
DEFAULT_OUT = ROOT / "Tests/Fixtures/release-bundles"
OWNED = "config"
IOS = {"platform": "ios", "versions": {"app": "0.6.2", "ui_catalog": "1.3", "config_schema": "2"}}


def bundle_world():
    """Bundle 12 at index seq 6: one app config component and one box-only config the app must never read."""
    world = vw.World()
    app = world.component("config", "data", "app-config", "1.0.0", ["mac", "ios"], [
        vw.f("policy.json", doc("policy", codingOrder="codex,claude,hermes", coding_job_limit=3, approvers=["TEST"])),
        vw.f("copy.json", doc("copy", onboardingTitle="TEST bundle 12")),
        vw.f("flags.json", doc("flags", **{"routineCards": True, "kill.view.routine_card": True}))])
    box = world.component("config", "data", "box-policy", "1.0.0", ["box"],
                          [vw.f("policy.json", doc("policy", codingOrder="hermes"))])
    manifest = world.files[world.signed_file("bundles/12.json", world.bundle(12, [app, box]), [vw.RELEASE])]
    world.signed_file("channels/stable.json", world.index([world.line(manifest, 12)], seq=6), [vw.RELEASE])
    expect = {
        "id": "signed-bundle-12",
        "description": "Fetched and verified like any bundle (TEST keys); only the app-targeted component is read.",
        "inputs": {"pins": "keys/pins.json", "keys": "keys/keys-2.json", "index": "config/channels/stable.json",
                   "manifest": "config/bundles/12.json", "blobs": "config/blobs/sha256", "channel": "stable",
                   "now": vw.NOW, "floors": dict(vw.FLOORS), "consumer": IOS, "install_id": vw.INSTALL_ID},
        "apply": ["app-config"],
        "reads": [r("policy", "codingOrder", "string", "claude,codex,hermes", "codex,claude,hermes"),
                  r("policy", "coding_job_limit", "integer", 2, 3, low=1, high=8),
                  r("policy", "approvers", "string_list", [], []),
                  r("copy", "onboardingTitle", "string", "Welcome", "TEST bundle 12"),
                  r("flags", "routineCards", "bool", False, True)],
        "views": [{"type": "routine_card", "killed": True}],
        "reports": [rep("denied_key", "policy", "approvers", "app-config")],
    }
    return world, expect


def case_files(case_id, components):
    """Archive files and the vector's component list for one case."""
    files, listed = {}, []
    for spec in components:
        name = spec[0]
        if spec[1] is None:
            listed.append({"name": name, "unreadable": True})
            continue
        data = ustar.build(spec[-1])
        if spec[1] == "corrupt":
            data = corrupt_header(data)
        rel = f"config/archives/{case_id}--{name}.tar"
        files[rel] = data
        listed.append({"name": name, "archive": rel})
    return files, listed


def check_case(vector, archives):
    """The reference decoder must give exactly the hand-written expectations."""
    return check_result(config_reference.decode([(c["name"], None if c.get("unreadable") else archives[c["archive"]])
                                                 for c in vector["components"]]), vector)


def check_result(result, vector):
    problems = []
    if result["reports"] != vector["reports"]:
        problems.append(f"reports {result['reports']} != {vector['reports']}")
    for read in vector["reads"]:
        bounds = (read["min"], read["max"]) if "min" in read else ()
        value, reason = config_reference.read(result, read["domain"], read["key"], read["type"], read["default"], *bounds)
        if value != read["expect"] or reason != read.get("report"):
            problems.append(f"read {read['domain']}.{read['key']}: {value!r}/{reason} != {read['expect']!r}/{read.get('report')}")
    for view in vector["views"]:
        if (view["type"] in result["killed_views"]) != view["killed"]:
            problems.append(f"view {view['type']}")
    return problems


def app_config_vectors():
    """P6b: config/app-config.json, the resolved app settings per bundle (AppConfig.swift, app_config_reference.py)."""
    files, cases, problems = {}, [], []
    for case_id, description, components, snapshot, reports in APP_CASES:
        archives, listed = case_files(f"app-{case_id}", components)
        files.update(archives)
        result = config_reference.decode([(c["name"], archives[c["archive"]]) for c in listed])
        got, read_reports = app_config_reference.resolve(result)
        want = app_expected(snapshot)
        if got != want:
            problems.append(f"app-{case_id}: snapshot {got} != {want}")
        if result["reports"] + read_reports != reports:
            problems.append(f"app-{case_id}: reports {result['reports'] + read_reports} != {reports}")
        cases.append({"id": case_id, "description": description, "components": listed, "snapshot": want,
                      "reports": reports})
    keys = [{"domain": d, "key": k, "type": t} for d, k, t, *_ in app_config_reference.KEYS]
    document = {"schema": "swarmhub/app-config-vectors/1",
                "note": "Generated by scripts/release/make_config_vectors.py (P6b). Resolved app settings per bundle; "
                        "an unset optional text is absent. TEST data only.",
                "keys": keys, "cases": cases}
    files["config/app-config.json"] = (json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
    return files, problems


def build():
    files, cases = {}, []
    for case_id, description, components, reads, views, reports in CASES:
        archives, listed = case_files(case_id, components)
        files.update(archives)
        cases.append({"id": case_id, "description": description, "components": listed, "reads": reads,
                      "views": [{"type": t, "killed": k} for t, k in views], "reports": reports})
    world, signed = bundle_world()
    files.update({f"config/{rel}": data for rel, data in world.files.items()})
    problems = [f"{c['id']}: {p}" for c in cases for p in check_case(c, files)]
    listed = {c["name"]: c for c in json.loads(files["config/bundles/12.json"])["signed"]["components"]}
    applied = [(name, files[f"config/blobs/sha256/{listed[name]['sha256']}"]) for name in signed["apply"]]
    problems += [f"signed-bundle-12: {p}" for p in check_result(config_reference.decode(applied), signed)]
    app_files, app_problems = app_config_vectors()
    files.update(app_files)
    problems += app_problems
    if problems:
        raise SystemExit("config vectors disagree with config_reference.py:\n" + "\n".join(problems))
    document = {"schema": "swarmhub/config-vectors/1",
                "note": "Generated by scripts/release/make_config_vectors.py. TEST keys only. See "
                        "docs/update-service/SCHEMAS.md §12.",
                "cases": cases, "bundle": signed}
    files["config/vectors.json"] = (json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
    return files, cases


def write(out):
    files, cases = build()
    shutil.rmtree(out / OWNED, ignore_errors=True)
    for rel, data in sorted(files.items()):
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return files, cases


def tree(directory):
    return sorted(str(p.relative_to(directory)) for p in (directory / OWNED).rglob("*") if p.is_file())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="compare a fresh regeneration with --out")
    args = parser.parse_args(argv)
    if args.check:
        with tempfile.TemporaryDirectory() as temp:
            write(Path(temp))
            left, right = tree(Path(temp)), tree(args.out)
            diffs = [f"only in regenerated: {p}" for p in sorted(set(left) - set(right))]
            diffs += [f"only in fixtures: {p}" for p in sorted(set(right) - set(left))]
            diffs += [f"differs: {p}" for p in sorted(set(left) & set(right))
                      if not filecmp.cmp(Path(temp) / p, args.out / p, shallow=False)]
        for line in diffs:
            print(line)
        print("config vectors: byte-identical" if not diffs else f"config vectors: {len(diffs)} differences")
        return 1 if diffs else 0
    files, cases = write(args.out)
    print(f"wrote {len(files)} files and {len(cases)} cases to {args.out / OWNED}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
