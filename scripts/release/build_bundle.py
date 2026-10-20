#!/usr/bin/env python3
"""Build an unsigned bundle (manifest body + blobs) from the repository (CORE-PHASES.md P1a; SCHEMAS.md §7, §9).

    python3 scripts/release/build_bundle.py --version N --label L --created TS \\
        (--previous MANIFEST | --repo DIR | --baseline) --out DIR [--layout FILE] [--root DIR]

Writes DIR/blobs/sha256/<sha256> and DIR/bundle-N.unsigned.json (the canonical JCS bytes of the body to sign).
The same sources and arguments give byte-identical output: ustar archives with mtime 0 and uid/gid 0, entries in
path order with every parent directory listed, modes normalised to 0755 (any exec bit set) or 0644.

What goes in is `bundle_layout.json`. Files are taken as SkillLibrary.extraFiles takes them: hidden names are
skipped, and so are `__pycache__` directories and `*.pyc` (interpreter caches, git-ignored). A symlink, a special
file, an unsafe name or (outside `tool`) a file that is not UTF-8 stops the build.

Class is derived, never declared (CORE-PLAN.md §2.3): a `tool` is `code`; any other component is `code` when a
file has an exec bit or an extension outside its kind's data list (`skill` .md; `config` .json .md .txt; `ui`
.json), so a skill with scripts is `code` as a whole. A `config` or `ui` that would be code stops the build.
`code_bearing` is true exactly when a code component is present.

`requires_component` (decision 2): a data component lists in `uses` the code components it relies on. When the
data component and a code component it uses both change in this bundle (new, or a different version than the
previous bundle), the build refuses unless the data component's `requires_component` names that code at its new
version or higher. Against the previous bundle, changed content needs a higher component version, and a lower
version is refused (going back is `republish`, never a build).
"""

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import jcs  # noqa: E402
import schemas  # noqa: E402
import ustar  # noqa: E402

DEFAULT_LAYOUT = HERE / "bundle_layout.json"
DATA_EXTENSIONS = {"skill": {".md"}, "config": {".json", ".md", ".txt"}, "ui": {".json"}}
LAYOUT_KEYS = {"kind", "name", "version", "targets", "sources", "uses", "requires", "requires_component", "note"}
SKIPPED_DIRS = {"__pycache__"}
SKIPPED_SUFFIXES = (".pyc",)
FRONTMATTER = re.compile(r"---\n(.*?)\n---\n", re.S)


class BuildError(Exception):
    pass


# Layout ----------------------------------------------------------------------------------------------------------

def load_layout(path):
    try:
        layout = jcs.loads(Path(path).read_bytes())
    except (OSError, jcs.JCSError) as error:
        raise BuildError(f"cannot read layout {path}: {error}") from error
    if not isinstance(layout, dict) or layout.get("schema") != "swarmhub/bundle-layout/1":
        raise BuildError(f"{path}: not a swarmhub/bundle-layout/1 file")
    if not isinstance(layout.get("components"), list) or not layout["components"]:
        raise BuildError(f"{path}: no components")
    for entry in layout["components"]:
        _check_layout_entry(entry)
    names = [entry["name"] for entry in layout["components"]]
    if len(set(names)) != len(names):
        raise BuildError(f"{path}: duplicate component names")
    return layout


def _check_layout_entry(entry):
    if not isinstance(entry, dict):
        raise BuildError("layout components must be objects")
    name = entry.get("name")
    where = f"layout component {name!r}"
    if set(entry) - LAYOUT_KEYS:
        raise BuildError(f"{where}: unknown members {sorted(set(entry) - LAYOUT_KEYS)}")
    if entry.get("kind") not in schemas.KINDS or not isinstance(name, str) or not schemas.NAME.fullmatch(name):
        raise BuildError(f"{where}: bad kind or name")
    if (entry["kind"] == "skill") == ("version" in entry):
        raise BuildError(f"{where}: skills take their version from SKILL.md; every other kind declares one")
    if "version" in entry and not (isinstance(entry["version"], str) and schemas.VERSION.fullmatch(entry["version"])):
        raise BuildError(f"{where}: bad version")
    sources = entry.get("sources")
    if not isinstance(sources, list) or not sources or not all(
            isinstance(s, dict) and set(s) <= {"from", "to"} and isinstance(s.get("from"), str)
            and isinstance(s.get("to", ""), str) for s in sources):
        raise BuildError(f"{where}: sources must be [{{from, to?}}]")
    uses = entry.get("uses", [])
    if not isinstance(uses, list) or not all(isinstance(u, str) for u in uses):
        raise BuildError(f"{where}: uses must be a list of component names")


# Sources ---------------------------------------------------------------------------------------------------------

def _mode(stat_result):
    return 0o755 if stat_result.st_mode & 0o111 else 0o644


def _add(files, path, data, mode, where):
    if not schemas.safe_relative(path):
        raise BuildError(f"{where}: unsafe archive path {path!r}")
    if path in files:
        raise BuildError(f"{where}: {path} comes from two sources")
    files[path] = (data, mode)


def _read_regular(path, where):
    if path.is_symlink():
        raise BuildError(f"{where}: {path} is a symlink")
    stat_result = path.lstat()
    if not path.is_file():
        raise BuildError(f"{where}: {path} is not a regular file")
    return path.read_bytes(), _mode(stat_result)


def collect(root, entry):
    """{archive path: (bytes, mode)} for one layout component."""
    where, files = f"component {entry['name']}", {}
    for source in entry["sources"]:
        base, prefix = root / source["from"], source.get("to", "")
        if base.is_symlink() or not base.exists():
            raise BuildError(f"{where}: source {source['from']} is missing or a symlink")
        if base.is_file():
            data, mode = _read_regular(base, where)
            _add(files, prefix or base.name, data, mode, where)
            continue
        for directory, dirnames, filenames in os.walk(base):
            current = Path(directory)
            for dirname in list(dirnames):
                if (current / dirname).is_symlink():
                    raise BuildError(f"{where}: {current / dirname} is a symlink")
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in SKIPPED_DIRS)
            for filename in sorted(filenames):
                if filename.startswith(".") or filename.endswith(SKIPPED_SUFFIXES):
                    continue
                rel = (current / filename).relative_to(base).as_posix()
                data, mode = _read_regular(current / filename, where)
                _add(files, f"{prefix}/{rel}" if prefix else rel, data, mode, where)
    if not files:
        raise BuildError(f"{where}: no files")
    if entry["kind"] != "tool":
        for path, (data, _) in files.items():
            try:
                data.decode("utf-8")
            except UnicodeDecodeError as error:
                raise BuildError(f"{where}: {path} is not UTF-8 text") from error
    return files


def archive(files):
    """Deterministic ustar bytes: every parent directory (0755) before its contents, entries in path order."""
    dirs = {"/".join(path.split("/")[:i]) for path in files for i in range(1, path.count("/") + 1)}
    entries = [{"name": d + "/", "type": "dir", "mode": 0o755} for d in dirs]
    entries += [{"name": p, "type": "file", "mode": mode, "data": data} for p, (data, mode) in files.items()]
    entries.sort(key=lambda e: tuple(e["name"].rstrip("/").split("/")))
    return ustar.build(entries)


def extension(path):
    base = path.rsplit("/", 1)[-1]
    dot = base.rfind(".")
    return base[dot:] if 0 < dot < len(base) - 1 else ""


def derive_class(kind, files):
    """`code` or `data` from the kind and the files (SCHEMAS.md §7 content rule)."""
    if kind == "tool":
        return "code"
    allowed = DATA_EXTENSIONS[kind]
    code_files = sorted(p for p, (_, mode) in files.items() if mode == 0o755 or extension(p) not in allowed)
    if code_files and kind in ("config", "ui"):
        raise BuildError(f"a {kind} component must be data, but holds {code_files[0]}")
    return "code" if code_files else "data"


def skill_version(name, files):
    data = files.get("SKILL.md", (None,))[0]
    match = FRONTMATTER.match(data.decode("utf-8")) if data is not None else None
    if not match:
        raise BuildError(f"skill {name}: SKILL.md with frontmatter is required")
    fields = dict(line.split(":", 1) for line in match.group(1).splitlines() if ":" in line and line[:1] != " ")
    fields = {k.strip(): v.strip().strip('"') for k, v in fields.items()}
    if fields.get("name") != name or not schemas.VERSION.fullmatch(fields.get("version", "")):
        raise BuildError(f"skill {name}: SKILL.md frontmatter needs name: {name} and a version like 1.2.3")
    return fields["version"]


# Bundle ----------------------------------------------------------------------------------------------------------

def build_component(root, entry):
    files = collect(root, entry)
    blob = archive(files)
    version = skill_version(entry["name"], files) if entry["kind"] == "skill" else entry["version"]
    component = {"kind": entry["kind"], "class": derive_class(entry["kind"], files), "name": entry["name"],
                 "version": version, "targets": list(entry["targets"]), "sha256": hashlib.sha256(blob).hexdigest(),
                 "size": len(blob), "path": entry["name"], "requires": dict(entry.get("requires", {})),
                 "requires_component": [dict(d) for d in entry.get("requires_component", [])]}
    return component, blob


def _vt(text):
    return schemas.version_tuple(text)


def check_against_previous(components, previous):
    """Component versions move forward with their content."""
    before = {c["name"]: c for c in (previous or {}).get("components", [])}
    for component in components:
        old = before.get(component["name"])
        if old is None:
            continue
        if _vt(component["version"]) < _vt(old["version"]):
            raise BuildError(f"{component['name']} {component['version']} is lower than {old['version']} in bundle "
                             f"{previous['version']}; going back is `republish`, not a build")
        if component["version"] == old["version"] and component["sha256"] != old["sha256"]:
            raise BuildError(f"{component['name']} changed but kept version {old['version']}; bump its version")


def changed(component, previous):
    old = {c["name"]: c for c in (previous or {}).get("components", [])}.get(component["name"])
    return old is None or old["version"] != component["version"]


def check_requires_component(components, uses, previous):
    """Every declared edge is valid, and every edge new data needs on new code is declared (decision 2)."""
    by_name = {c["name"]: c for c in components}
    for component in components:
        for dep in component["requires_component"]:
            target = by_name.get(dep.get("name"))
            if target is None or target is component:
                raise BuildError(f"{component['name']}: requires_component {dep.get('name')!r} is not another "
                                 f"component of this bundle")
            if _vt(target["version"]) < _vt(dep["min_version"]):
                raise BuildError(f"{component['name']}: requires {target['name']} >= {dep['min_version']}, "
                                 f"bundle has {target['version']}")
            if not set(component["targets"]) <= set(target["targets"]):
                raise BuildError(f"{component['name']}: {target['name']} does not reach every target it needs")
    for component in components:
        for name in uses.get(component["name"], []):
            code = by_name.get(name)
            if code is None or code["class"] != "code":
                raise BuildError(f"{component['name']}: uses {name!r}, which is not a code component of this bundle")
            if component["class"] != "data" or not (changed(component, previous) and changed(code, previous)):
                continue
            declared = [d for d in component["requires_component"] if d["name"] == name]
            if not declared or _vt(declared[0]["min_version"]) < _vt(code["version"]):
                raise BuildError(f"missing requires_component: {component['name']} {component['version']} uses "
                                 f"{name}, which changes to {code['version']} in this bundle; declare "
                                 f'{{"name": "{name}", "min_version": "{code["version"]}"}} in the layout')


def build(*, version, label, created, previous, layout_path=DEFAULT_LAYOUT, root=ROOT):
    """(manifest body, {sha256: blob}). previous: the previous bundle's body, or None for a baseline."""
    layout = load_layout(layout_path)
    if previous is not None and version <= previous["version"]:
        raise BuildError(f"bundle version {version} must be above the previous bundle {previous['version']}")
    components, blobs = [], {}
    for entry in layout["components"]:
        component, blob = build_component(Path(root), entry)
        components.append(component)
        blobs[component["sha256"]] = blob
    check_against_previous(components, previous)
    check_requires_component(components, {e["name"]: e.get("uses", []) for e in layout["components"]}, previous)
    body = {"schema": "swarmhub/bundle/1", "version": version, "label": label, "created": created,
            "code_bearing": any(c["class"] == "code" for c in components),
            "requires": dict(layout.get("requires", {})), "components": components}
    try:
        jcs.check(body)
        schemas.check_bundle(body)
    except (jcs.JCSError, schemas.Reject) as error:
        raise BuildError(f"bundle fails the schema: {error}") from error
    return body, blobs


def write_build(out, body, blobs):
    out = Path(out)
    if out.exists() and any(out.iterdir()):
        raise BuildError(f"{out} is not empty")
    (out / "blobs/sha256").mkdir(parents=True, exist_ok=True)
    for digest, blob in sorted(blobs.items()):
        (out / "blobs/sha256" / digest).write_bytes(blob)
    manifest = out / f"bundle-{body['version']}.unsigned.json"
    manifest.write_bytes(jcs.canonical(body))
    return manifest


def latest_published(repo):
    """The body of the highest bundles/<N>.json in a published directory, or None."""
    found = [(int(p.stem), p) for p in (Path(repo) / "bundles").glob("*.json") if p.stem.isdigit()]
    if not found:
        return None
    return read_body(max(found)[1])


def read_body(path):
    doc = jcs.loads(Path(path).read_bytes())
    return doc["signed"] if isinstance(doc, dict) and set(doc) == {"signed", "signatures"} else doc


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--created", required=True, help="YYYY-MM-DDTHH:MM:SSZ (fixed, so rebuilds are identical)")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--previous", type=Path, help="previous bundle manifest (signed or unsigned)")
    group.add_argument("--repo", type=Path, help="published directory: compare with its highest bundle")
    group.add_argument("--baseline", action="store_true", help="first bundle: nothing to compare with")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--layout", type=Path, default=DEFAULT_LAYOUT)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        previous = read_body(args.previous) if args.previous else latest_published(args.repo) if args.repo else None
        if args.repo and previous is None:
            raise BuildError(f"{args.repo} has no published bundle; use --baseline for the first one")
        body, blobs = build(version=args.version, label=args.label, created=args.created, previous=previous,
                            layout_path=args.layout, root=args.root)
        manifest = write_build(args.out, body, blobs)
    except (BuildError, jcs.JCSError, OSError) as error:
        print(f"build-bundle: {error}", file=sys.stderr)
        return 1
    for c in body["components"]:
        print(f"  {c['kind']:6} {c['class']:4} {c['name']} {c['version']} -> {','.join(c['targets'])}")
    print(f"bundle {body['version']} code_bearing={str(body['code_bearing']).lower()} -> {manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
