"""P2c: the embedded baseline + bootstrap package (baseline.py) and the build check (check_baseline.py).

    python3 scripts/test_release_baseline.py

Keys: the TEST fixture keys, plus, for the one case that must pass as a release, throwaway keys with random seeds made
in memory per test (never written outside a temp folder, never trusted anywhere).
"""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))

import baseline  # noqa: E402
import build_bundle  # noqa: E402
import check_baseline  # noqa: E402
import ed25519_ref  # noqa: E402
import jcs  # noqa: E402
import keys  # noqa: E402
import publish  # noqa: E402
import sign  # noqa: E402
import vector_world  # noqa: E402

ISSUED, FAR = "2026-10-20T00:00:00Z", "2099-01-01T00:00:00Z"


class SeedSigner(sign.Signer):
    """An in-memory key under any key_id (the file backend refuses non-TEST ids)."""

    def __init__(self, key_id, seed=None):
        self.key_id, self._seed = key_id, seed if seed is not None else os.urandom(32)

    def public_key(self):
        return ed25519_ref.public_key(self._seed)

    def sign(self, message):
        return ed25519_ref.sign(self._seed, message)


def signed_baseline(out, roots, release, root=ROOT):
    """A baseline of this checkout signed by roots[0] (pins: all roots) and the release signer."""
    out.mkdir(parents=True)
    pins = jcs.canonical(keys.pins_document(1, [(r.key_id, sign.public_hex(r)) for r in roots]))
    body = keys.key_manifest(1, ISSUED, [(release.key_id, sign.public_hex(release), ["bundle", "index"], FAR)])
    (out / "pins.json").write_bytes(pins)
    (out / "keys.json").write_bytes(keys.sign_keys(jcs.canonical(body), pins, [roots[0]]))
    manifest, blobs = build_bundle.build(version=3, label="baseline", created=ISSUED, previous=None, root=root)
    publish.publish_body(out, manifest, {c["name"]: blobs[c["sha256"]] for c in manifest["components"]},
                         signer=release, pins_bytes=pins, channel="stable", issued=ISSUED, expires=FAR, seq=1)
    return out


def tree(folder):
    return {p.relative_to(folder).as_posix(): p.read_bytes() for p in sorted(Path(folder).rglob("*")) if p.is_file()}


class BaselineCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="p2c-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def embed(self, name="res", configuration="debug", **options):
        out = self.tmp / name
        return out, baseline.embed(out, configuration, **options)

    def package(self, out):
        return out / "Bootstrap" / baseline.package_name()


class EmbedTest(BaselineCase):
    def test_debug_embed_writes_a_verified_baseline_and_package(self):
        out, problems = self.embed()
        self.assertEqual(problems, [])
        files = tree(out)
        self.assertIn("Baseline/pins.json", files)
        self.assertIn("Baseline/keys.json", files)
        self.assertIn("Baseline/channels/stable.json", files)
        self.assertIn("Baseline/bundles/1.json", files)
        self.assertEqual(sorted(p for p in files if p.startswith("Bootstrap/")),
                         ["Bootstrap/swarmhub-updater-1.0.0.tar", "Bootstrap/swarmhub-updater-1.0.0.tar.sha256"])
        self.assertEqual(check_baseline.check(out, "debug"), [])

    def test_embed_is_byte_identical_across_runs(self):
        first, _ = self.embed("one")
        second, _ = self.embed("two")
        self.assertEqual(tree(first), tree(second))

    def test_shown_digest_matches_the_packaged_bytes(self):
        out, _ = self.embed()
        package = self.package(out)
        line = (package.parent / (package.name + ".sha256")).read_text(encoding="ascii")
        self.assertEqual(line, "%s  %s\n" % (hashlib.sha256(package.read_bytes()).hexdigest(), package.name))
        for tool in (["sha256sum"], ["shasum", "-a", "256"]):
            if shutil.which(tool[0]):
                printed = subprocess.run(tool + [package.name], cwd=str(package.parent), capture_output=True,
                                         text=True, check=True).stdout
                self.assertEqual(printed, line)

    def test_package_is_the_updater_and_the_baseline_pins(self):
        out, _ = self.embed()
        with tarfile.open(str(self.package(out))) as archive:
            members = {m.name: m for m in archive.getmembers()}
            pins = archive.extractfile("swarmhub-updater/pins.json").read()
            launcher = members["swarmhub-updater/bin/swarmhub-update"]
            self.assertEqual(launcher.mode, 0o755)
            source = ROOT / "Resources/Updater/swarmhub_update"
            expected = sorted("swarmhub-updater/swarmhub_update/" + p.name for p in source.glob("*.py"))
            self.assertEqual(sorted(n for n in members if n.startswith("swarmhub-updater/swarmhub_update/")
                                    and members[n].isfile()), expected)
            for name in expected:
                self.assertEqual(archive.extractfile(name).read(), (source / name.rsplit("/", 1)[1]).read_bytes())
                self.assertEqual(members[name].mode, 0o644)
        self.assertEqual(pins, (out / "Baseline/pins.json").read_bytes())
        self.assertTrue(all(m.mtime == 0 and m.uid == 0 for m in members.values()))

    def test_baseline_carries_what_the_app_ships(self):
        """The app's compiled-in skills and manager text are the baseline's archives, byte for byte."""
        out, _ = self.embed()
        manifest = json.loads((out / "Baseline/bundles/1.json").read_text())["signed"]
        for component in manifest["components"]:
            blob = (out / "Baseline/blobs/sha256" / component["sha256"]).read_bytes()
            with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
                files = {m.name: archive.extractfile(m).read() for m in archive.getmembers() if m.isfile()}
            if component["kind"] == "skill":
                source = ROOT / "Resources/Skills" / component["name"]
                for rel, data in files.items():
                    origin = (ROOT / "Resources/BotManager/recipes" / rel[len("references/"):]
                              if component["name"] == "swarmhub-manager" and rel.startswith("references/")
                              else source / rel)
                    self.assertEqual(data, origin.read_bytes(), rel)
                self.assertIn("SKILL.md", files)
            elif component["name"] == "manager-prompts":
                for rel, data in files.items():
                    self.assertEqual(data, (ROOT / "Resources/BotManager" / rel).read_bytes(), rel)

    def test_ios_gets_the_baseline_without_package_or_box_archives(self):
        out, problems = self.embed(ios=True)
        self.assertEqual(problems, [])
        self.assertFalse((out / "Bootstrap").exists())
        manifest = json.loads((out / "Baseline/bundles/1.json").read_text())["signed"]
        ios = sorted(c["sha256"] for c in manifest["components"] if "ios" in c["targets"])
        self.assertTrue(ios)
        self.assertEqual(sorted(p.name for p in (out / "Baseline/blobs/sha256").iterdir()), ios)
        self.assertIn("Bootstrap: expected exactly", " ".join(check_baseline.check(out, "debug")))
        (out / "Bootstrap").mkdir()
        self.assertIn("Bootstrap: present in an iOS build", check_baseline.check(out, "debug", ios=True))
        mac, _ = self.embed("mac")
        box = next(c for c in manifest["components"] if c["targets"] == ["box"])
        shutil.copy(str(mac / "Baseline/blobs/sha256" / box["sha256"]), str(out / "Baseline/blobs/sha256"))
        self.assertIn("Baseline: blobs no iOS component uses: %s" % [box["sha256"]],
                      check_baseline.check(out, "debug", ios=True))

    def test_embed_writes_only_its_two_folders(self):
        """Sparkle's framework, Info.plist and the other resources are left as they are."""
        out = self.tmp / "res"
        (out / "Sparkle.framework/Versions/B").mkdir(parents=True)
        (out / "Sparkle.framework/Versions/B/Sparkle").write_bytes(b"framework")
        (out / "Info.plist").write_bytes(b"<plist>SUFeedURL</plist>")
        (out / "Skills/x").mkdir(parents=True)
        (out / "Skills/x/SKILL.md").write_bytes(b"x")
        (out / "Baseline").mkdir()
        (out / "Baseline/stale").write_bytes(b"old build")
        before = {k: v for k, v in tree(out).items() if not k.startswith(baseline.PARTS)}
        self.embed()
        after = tree(out)
        self.assertEqual({k: v for k, v in after.items() if not k.startswith(baseline.PARTS)}, before)
        self.assertNotIn("Baseline/stale", after)


class ReleaseRuleTest(BaselineCase):
    def test_release_without_a_baseline_dir_fails(self):
        with self.assertRaises(baseline.BaselineError):
            self.embed(configuration="release")
        self.assertEqual(baseline.main(["embed", "--configuration", "release", "--out", str(self.tmp / "cli")]), 1)
        self.assertFalse((self.tmp / "cli/Baseline").exists())

    def test_release_refuses_test_keys_everywhere(self):
        out, _ = self.embed()
        problems = "\n".join(check_baseline.check(out, "release"))
        for where in ("pinned root TEST-root-1", "pinned root TEST-root-2", "key manifest signature TEST-root-1",
                      "listed release key TEST-release-1", "index stable signature TEST-release-1",
                      "bundle 1 signature TEST-release-1"):
            self.assertIn("release build: %s is a TEST key" % where, problems)
        self.assertEqual(check_baseline.main(["--configuration", "release", str(out)]), 1)
        source = baseline.make_test(self.tmp / "test-signed")
        out, problems = self.embed("rel", "release", baseline_dir=source)
        self.assertTrue(problems)
        self.assertEqual(baseline.main(["embed", "--configuration", "release", "--baseline-dir", str(source),
                                        "--out", str(self.tmp / "rel-cli")]), 1)

    def test_release_passes_with_non_test_keys(self):
        source = signed_baseline(self.tmp / "real", [SeedSigner("root-a"), SeedSigner("root-b")],
                                 SeedSigner("release-a"))
        out, problems = self.embed(configuration="release", baseline_dir=source)
        self.assertEqual(problems, [])
        self.assertEqual(check_baseline.main(["--configuration", "release", str(out)]), 0)
        with tarfile.open(str(self.package(out))) as archive:
            self.assertEqual(archive.extractfile("swarmhub-updater/pins.json").read(), (source / "pins.json").read_bytes())

    def test_one_test_root_among_real_ones_fails(self):
        source = signed_baseline(self.tmp / "mixed", [SeedSigner("root-a"), sign.FileKeySigner(
            "TEST-root-2", vector_world.seed("TEST-root-2"))], SeedSigner("release-a"))
        _, problems = self.embed(configuration="release", baseline_dir=source)
        self.assertEqual(problems, ["release build: pinned root TEST-root-2 is a TEST key"])

    def test_a_renamed_test_key_fails(self):
        renamed = SeedSigner("release-1", vector_world.seed("TEST-release-1"))
        source = signed_baseline(self.tmp / "renamed", [SeedSigner("root-a")], renamed)
        _, problems = self.embed(configuration="release", baseline_dir=source)
        self.assertIn("release build: index stable signature release-1 is a TEST key", problems)
        self.assertIn("release build: bundle 3 signature release-1 is a TEST key", problems)

    def test_without_baseline_is_release_only_and_embeds_nothing(self):
        out, _ = self.embed()
        _, problems = self.embed(configuration="release", without_baseline=True)
        self.assertEqual(problems, [])
        self.assertFalse((out / "Baseline").exists() or (out / "Bootstrap").exists())
        with self.assertRaises(baseline.BaselineError):
            self.embed(without_baseline=True)
        out, _ = self.embed("again")
        self.assertIn("Baseline: present in a build made without a baseline",
                      check_baseline.check(out, "release", without_baseline=True))


class CheckTest(BaselineCase):
    def test_altered_package_or_digest_fails(self):
        out, _ = self.embed()
        package = self.package(out)
        good = package.read_bytes()
        data = bytearray(good)
        data[700] ^= 1
        package.write_bytes(bytes(data))
        problems = check_baseline.check(out, "debug")
        self.assertIn("Bootstrap: swarmhub-updater-1.0.0.tar.sha256 does not match the package bytes", problems)
        package.write_bytes(good)
        sidecar = package.parent / (package.name + ".sha256")
        sidecar.write_text("%s  %s\n" % ("0" * 64, package.name))
        self.assertIn("Bootstrap: swarmhub-updater-1.0.0.tar.sha256 does not match the package bytes",
                      check_baseline.check(out, "debug"))
        sidecar.write_text(hashlib.sha256(good).hexdigest() + " " + package.name)
        self.assertIn("Bootstrap: swarmhub-updater-1.0.0.tar.sha256 is not '<sha256>  swarmhub-updater-1.0.0.tar'",
                      check_baseline.check(out, "debug"))

    def test_package_with_other_pins_fails(self):
        out, _ = self.embed()
        other = jcs.canonical(keys.pins_document(1, [("TEST-rogue", vector_world.public_hex("TEST-rogue"))]))
        package = baseline.bootstrap_package(other)
        self.package(out).write_bytes(package)
        (out / "Bootstrap" / (self.package(out).name + ".sha256")).write_text(
            baseline.digest_line(package, self.package(out).name))
        self.assertEqual(check_baseline.check(out, "debug"),
                         ["Bootstrap: swarmhub-updater-1.0.0.tar is not this checkout's updater with Baseline/pins.json"])

    def test_tampered_baseline_fails(self):
        out, _ = self.embed()
        blob = next((out / "Baseline/blobs/sha256").iterdir())
        blob.write_bytes(blob.read_bytes() + b"\0" * 512)
        self.assertTrue(any("does not verify: blob_size_mismatch" in p for p in check_baseline.check(out, "debug")))
        out, _ = self.embed("manifest")
        manifest = out / "Baseline/bundles/1.json"
        manifest.write_bytes(manifest.read_bytes().replace(b'"label":"baseline"', b'"label":"baselinf"'))
        self.assertTrue(any("manifest_hash_mismatch" in p for p in check_baseline.check(out, "debug")))

    def test_stale_baseline_fails(self):
        """A baseline built from other skill text than this checkout's is refused."""
        root = self.tmp / "checkout"
        for rel in ("Resources/Skills", "Resources/BotManager", "Resources/Updater", "scripts/release",
                    "Tests/Fixtures/release-bundles/keys"):
            shutil.copytree(str(ROOT / rel), str(root / rel), ignore=shutil.ignore_patterns("__pycache__"))
        out, problems = self.embed(root=root)
        self.assertEqual(problems, [])
        skill = root / "Resources/Skills/swarmhub-feedback/SKILL.md"
        skill.write_text(skill.read_text() + "\nchanged\n")
        self.assertIn("Baseline: component swarmhub-feedback differs from this checkout (stale baseline)",
                      check_baseline.check(out, "debug", root=root))


class BuildScriptTest(unittest.TestCase):
    """The build scripts call the embed and the check; the Sparkle steps are still there."""

    def read(self, rel):
        return (ROOT / rel).read_text(encoding="utf-8")

    def test_mac_build_embeds_and_package_checks_the_signed_app(self):
        build = self.read("scripts/build.sh")
        self.assertIn('BASELINE_ARGS=(--configuration "$BUILD_CONFIGURATION" --out "$BUILD_DIR/AgentApp.resources")', build)
        self.assertIn('python3 -B "$ROOT_DIR/scripts/release/baseline.py" embed "${BASELINE_ARGS[@]}"', build)
        package = self.read("scripts/package-release.sh")
        self.assertIn('cp -R "$BUILD_DIR/AgentApp.resources/$PART" "$APP_DIR/Contents/Resources/$PART"', package)
        check = package.index('scripts/release/check_baseline.py" "${CHECK_ARGS[@]}" "$APP_DIR/Contents/Resources"')
        self.assertGreater(check, package.index('/usr/bin/codesign --verify --deep --strict "$APP_DIR"'))
        self.assertLess(check, package.index('/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"'))
        for sparkle in ('python3 "$ROOT_DIR/scripts/configure-updates.py" "$CONFIGURED_PLIST" "${CONFIG_ARGS[@]}"',
                        'ensure_sparkle', '/usr/bin/ditto "$BUILD_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"',
                        '/usr/bin/codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"',
                        'cp "$CONFIGURED_PLIST" "$APP_DIR/Contents/Info.plist"'):
            self.assertIn(sparkle, package)

    def test_ios_build_embeds_the_baseline_without_the_updater(self):
        generator = self.read("scripts/generate-ios-project.py")
        self.assertIn('--ios --out "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"', generator)
        project = self.read("Apps/iOS/SwarmHub.xcodeproj/project.pbxproj")
        self.assertIn('name = "Embed baseline"', project)
        self.assertIn("scripts/release/baseline.py", project)
        self.assertNotIn("Bootstrap", project)
        script = self.read("scripts/build-ios.sh")
        self.assertIn('check_baseline.py" --configuration "$BASELINE_CONFIGURATION" --ios', script)


if __name__ == "__main__":
    unittest.main()
