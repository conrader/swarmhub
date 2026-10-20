#!/usr/bin/env python3
"""The baseline bundle and the bootstrap package embedded in the app builds (CORE-PHASES.md P2c; CORE-PLAN.md §3.1,
§3.5). Stdlib only.

    baseline.py embed --configuration debug|release --out RESOURCES [--baseline-dir DIR] [--ios]
                      [--without-baseline]
    baseline.py make-test --out DIR        a TEST-signed baseline in the service layout (tests, debug builds)

`embed` writes two folders into RESOURCES (the app's resource folder) and nothing else:

    Baseline/   pins.json, keys.json, channels/<channel>.json, bundles/<N>.json, blobs/sha256/<sha256>
    Bootstrap/  swarmhub-updater-<VERSION>.tar and swarmhub-updater-<VERSION>.tar.sha256 (Mac only)

Baseline is the service layout (SCHEMAS.md §1) plus the pin file, so the box updater can take it as a staged folder
(`apply --staged`) and the apps can read it offline. A debug build signs it here with TEST keys from the public fixed
seeds. A release build takes it from `--baseline-dir` (made with real keys by the P1b ceremony: `build_bundle.py
--baseline`, `keys.py sign-keys --production`, `publish.py --production`) and never signs anything itself.

The bootstrap package is a deterministic ustar of the box updater (`Resources/Updater/bin`, `swarmhub_update/`) and
the baseline's pin file, all under `swarmhub-updater/`: the launcher 0755, the rest 0644, mtime 0. The `.sha256` file
is `<hex>  <file name>`, as `shasum -a 256` and `sha256sum` print it. iOS (`--ios`) gets no package and only the
blobs of components that target `ios`: the manifest still lists every component, but box archives stay out of the app.

After writing, `embed` runs `check_baseline.py` on RESOURCES; a release configuration therefore fails when any pinned
root or signature uses a TEST- key. `--without-baseline` (release only) removes both folders and embeds nothing: the
app then works as before P2c. It exists so a Sparkle release can still ship before real keys exist (P1b).
"""

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import build_bundle  # noqa: E402
import jcs  # noqa: E402
import keys  # noqa: E402
import publish  # noqa: E402
import sign  # noqa: E402
import vector_world  # noqa: E402

UPDATER_DIR = "Resources/Updater"
PACKAGE_TOP = "swarmhub-updater"
CHANNEL = "stable"
TEST_ROOTS = ("TEST-root-1", "TEST-root-2")
TEST_RELEASE = "TEST-release-1"
TEST_VERSION, TEST_LABEL = 1, "baseline"
TEST_CREATED = "2026-10-20T00:00:00Z"
TEST_FAR = "2099-01-01T00:00:00Z"  # the TEST baseline never expires on the real clock
PARTS = ("Baseline", "Bootstrap")


class BaselineError(Exception):
    pass


def updater_version(root=ROOT):
    """VERSION from swarmhub_update/__init__.py, read as text (the package is not imported from here)."""
    for line in (Path(root) / UPDATER_DIR / "swarmhub_update/__init__.py").read_text(encoding="utf-8").splitlines():
        if line.startswith("VERSION = "):
            return line.split('"')[1]
    raise BaselineError("swarmhub_update/__init__.py has no VERSION")


def package_name(root=ROOT):
    return f"{PACKAGE_TOP}-{updater_version(root)}.tar"


def bootstrap_package(pins_bytes, root=ROOT):
    """The deterministic package bytes: the updater as in the checkout, plus this pin file."""
    entry = {"name": PACKAGE_TOP, "kind": "tool", "sources": [
        {"from": f"{UPDATER_DIR}/bin", "to": f"{PACKAGE_TOP}/bin"},
        {"from": f"{UPDATER_DIR}/swarmhub_update", "to": f"{PACKAGE_TOP}/swarmhub_update"}]}
    try:
        files = build_bundle.collect(Path(root), entry)
    except build_bundle.BuildError as error:
        raise BaselineError(str(error)) from error
    # Modes do not depend on the checkout's exec bits: the launcher runs, the rest is read.
    files = {path: (data, 0o755 if path.startswith(f"{PACKAGE_TOP}/bin/") else 0o644)
             for path, (data, _) in files.items()}
    if f"{PACKAGE_TOP}/bin/swarmhub-update" not in files:
        raise BaselineError("the updater launcher bin/swarmhub-update is missing")
    files[f"{PACKAGE_TOP}/pins.json"] = (bytes(pins_bytes), 0o644)
    return build_bundle.archive(files)


def digest_line(package_bytes, name):
    return f"{hashlib.sha256(package_bytes).hexdigest()}  {name}\n"


def _signer(key_id):
    return sign.FileKeySigner(key_id, vector_world.seed(key_id))


def make_test(out, root=ROOT):
    """A TEST-signed baseline of this checkout in OUT (service layout + pins.json). Deterministic."""
    out = Path(out)
    if out.exists() and any(out.iterdir()):
        raise BaselineError(f"{out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    pins = jcs.canonical(keys.pins_document(1, [(k, vector_world.public_hex(k)) for k in TEST_ROOTS]))
    body = keys.key_manifest(1, TEST_CREATED, [
        (TEST_RELEASE, vector_world.public_hex(TEST_RELEASE), ["bundle", "index"], TEST_FAR)])
    (out / "pins.json").write_bytes(pins)
    (out / "keys.json").write_bytes(keys.sign_keys(jcs.canonical(body), pins, [_signer(TEST_ROOTS[0])]))
    manifest, blobs = build_bundle.build(version=TEST_VERSION, label=TEST_LABEL, created=TEST_CREATED, previous=None,
                                         root=root)
    by_name = {c["name"]: blobs[c["sha256"]] for c in manifest["components"]}
    publish.publish_body(out, manifest, by_name, signer=_signer(TEST_RELEASE), pins_bytes=pins, channel=CHANNEL,
                         issued=TEST_CREATED, expires=TEST_FAR, seq=1)
    return out


def _layout_files(source):
    """The service-layout files of a baseline folder (relative paths), refusing anything that is not one."""
    source = Path(source)
    wanted = [Path("pins.json"), Path("keys.json")]
    for folder, pattern in (("channels", "*.json"), ("bundles", "*.json"), ("blobs/sha256", "*")):
        wanted += sorted(p.relative_to(source) for p in (source / folder).glob(pattern))
    for rel in wanted:
        path = source / rel
        if path.is_symlink() or not path.is_file():
            raise BaselineError(f"baseline {source}: {rel} is missing, a symlink or not a file")
    return wanted


def copy_baseline(source, target):
    target.mkdir(parents=True)
    for rel in _layout_files(source):
        (target / rel).parent.mkdir(parents=True, exist_ok=True)
        (target / rel).write_bytes((Path(source) / rel).read_bytes())


def keep_ios_blobs(folder):
    """Remove the blobs no iOS-targeted component of any bundle in FOLDER uses."""
    keep = set()
    for path in (folder / "bundles").glob("*.json"):
        keep |= {c["sha256"] for c in build_bundle.read_body(path)["components"] if "ios" in c["targets"]}
    for blob in (folder / "blobs/sha256").iterdir():
        if blob.name not in keep:
            blob.unlink()


def embed(out, configuration, *, baseline_dir=None, ios=False, without_baseline=False, root=ROOT):
    """Write Baseline/ (and, for the Mac, Bootstrap/) into OUT, then check them. Returns the problems found."""
    import check_baseline  # here, so `make-test` alone does not need it

    if configuration not in ("debug", "release"):
        raise BaselineError("configuration must be debug or release")
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for part in PARTS:
        if (out / part).is_symlink() or (out / part).is_file():
            (out / part).unlink()
        elif (out / part).exists():
            shutil.rmtree(out / part)
    if without_baseline:
        if configuration != "release":
            raise BaselineError("--without-baseline is for release builds only; debug builds embed a TEST baseline")
        return check_baseline.check(out, configuration, ios=ios, without_baseline=True, root=root)
    if baseline_dir is None and configuration == "release":
        raise BaselineError("a release build needs a baseline signed with real keys (P1b): set SWARMHUB_BASELINE_DIR "
                            "(Mac only: SWARMHUB_RELEASE_WITHOUT_BASELINE=1 ships without one)")
    if baseline_dir is None:
        make_test(out / "Baseline", root=root)
    else:
        copy_baseline(Path(baseline_dir), out / "Baseline")
    if ios:
        keep_ios_blobs(out / "Baseline")
    else:
        package = bootstrap_package((out / "Baseline/pins.json").read_bytes(), root=root)
        name = package_name(root)
        (out / "Bootstrap").mkdir()
        (out / "Bootstrap" / name).write_bytes(package)
        (out / "Bootstrap" / (name + ".sha256")).write_text(digest_line(package, name), encoding="ascii")
    return check_baseline.check(out, configuration, ios=ios, root=root)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    e = sub.add_parser("embed", help="write Baseline/ and Bootstrap/ into an app resource folder, then check them")
    e.add_argument("--configuration", required=True, choices=("debug", "release"))
    e.add_argument("--out", type=Path, required=True)
    e.add_argument("--baseline-dir", type=Path, help="a baseline signed elsewhere (required for release)")
    e.add_argument("--ios", action="store_true", help="iOS: no bootstrap package, only blobs that target ios")
    e.add_argument("--without-baseline", action="store_true", help="release only: embed nothing")
    e.add_argument("--root", type=Path, default=ROOT)
    t = sub.add_parser("make-test", help="a TEST-signed baseline in the service layout")
    t.add_argument("--out", type=Path, required=True)
    t.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        if args.command == "make-test":
            make_test(args.out, root=args.root)
            print(f"TEST baseline -> {args.out}")
            return 0
        problems = embed(args.out, args.configuration, baseline_dir=args.baseline_dir, ios=args.ios,
                         without_baseline=args.without_baseline, root=args.root)
    except (BaselineError, build_bundle.BuildError, keys.KeysError, publish.PublishError, sign.SignerError,
            jcs.JCSError, OSError) as error:
        print(f"baseline: {error}", file=sys.stderr)
        return 1
    for problem in problems:
        print(f"baseline: {problem}", file=sys.stderr)
    if problems:
        return 1
    if args.without_baseline:
        print("WARNING: release build without an embedded baseline or bootstrap package (P1b keys missing).",
              file=sys.stderr)
        return 0
    package = args.out / "Bootstrap" / package_name(args.root)
    if package.exists():
        print(f"bootstrap package {package.name} sha256 {hashlib.sha256(package.read_bytes()).hexdigest()}")
    print(f"baseline ({args.configuration}) -> {args.out / 'Baseline'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
