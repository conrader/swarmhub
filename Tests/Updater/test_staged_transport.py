"""P4b: run the Mac's actual box-side transport script against the isolated real updater launcher, TEST keys only.
Swift is unavailable on Linux: app tests verify construction/selection and this suite executes the script's bytes.
No servers, real boxes or update hosts; Hermes and everything outside skills/swarmhub + updater state stay intact.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import (CliCase, ROOT, PROFILES_DOC, box_snapshot, changed, component,  # noqa: E402
                          source_components)

MAC = ROOT / "Sources/AgentApp/Updates/StagedInstall.swift"
RENDERS = ROOT / "Tests/Fixtures/release-bundles/renders"


def transport_command(files, profiles, updater):
    """Instantiate the exact Swift multiline shell literal, substituting only its three interpolated values."""
    source = MAC.read_text()
    literal = source.split('return """\n        python3 -I -B', 1)[1].split('\n        """', 1)[0]
    literal = textwrap.dedent('        python3 -I -B' + literal)
    payload = base64.b64encode(json.dumps({p: base64.b64encode(b).decode() for p, b in files.items()}).encode()).decode()
    rows = base64.b64encode(json.dumps(profiles).encode()).decode()
    return literal.replace('\\(payload)', payload).replace('\\(profiles)', rows).replace('\\(updater)', str(updater)) + '\n'


class StagedTransport(CliCase):
    def setUp(self):
        super().setUp()
        shutil.copytree(ROOT / "Resources/Updater/swarmhub_update", self.prefix / "swarmhub_update")
        (self.prefix / "bin").mkdir()
        self.launcher = self.prefix / "bin/swarmhub-update"
        shutil.copyfile(ROOT / "Resources/Updater/bin/swarmhub-update", self.launcher)
        self.launcher.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), XDG_STATE_HOME=str(self.home / ".local/state"),
                        PYTHONDONTWRITEBYTECODE="1", HERMES_INSTALL_DIR=str(self.tmp / "no-hermes-install"))
        self.original = box_snapshot(self.home)

    def real(self, *args):
        result = subprocess.run([str(self.launcher), *args], env=self.env, text=True, capture_output=True, timeout=90)
        self.assertTrue(result.stdout, result.stderr)
        return result.returncode, json.loads(result.stdout)

    def transport(self, folder, profiles=None, mutate=None):
        manifest = json.loads(next((folder / "bundles").iterdir()).read_bytes())["signed"]
        wanted = {c["sha256"] for c in manifest["components"] if "box" in c["targets"]}
        files = {p.relative_to(folder).as_posix(): p.read_bytes() for p in folder.rglob("*")
                 if p.is_file() and p.name != "profiles.json" and ("sha256" not in p.parts or p.name in wanted)}
        self.assertTrue(all(not p.startswith("blobs/") or p.rsplit("/", 1)[1] in wanted for p in files))
        if mutate:
            mutate(files)
        rows = (profiles or PROFILES_DOC)["profiles"]
        command = transport_command(files, rows, self.launcher)
        result = subprocess.run(["/bin/sh"], input=command, env=self.env, text=True, capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.state.glob("mac-stage-*")), [])
        return self.real("status")[1]

    def assert_confined(self):
        outside = [p for p in changed(self.original, box_snapshot(self.home))
                   if not (p.startswith(".local/state/swarmhub-update/") or
                           p.startswith(".hermes/skills/swarmhub/") or
                           p.startswith(".hermes/profiles/coder_2/skills/swarmhub/"))]
        # Directory entries at the allowed roots are created too.
        outside = [p for p in outside if p not in {".local", ".local/state", ".local/state/swarmhub-update",
                                                   ".hermes/skills/swarmhub", ".hermes/profiles/coder_2/skills",
                                                   ".hermes/profiles/coder_2/skills/swarmhub"}]
        self.assertEqual(outside, [])
        self.assert_no_pycache()

    def test_real_release_bytes_render_all_four_skills_as_todays_goldens(self):
        out = self.tmp / "built"
        build = subprocess.run([sys.executable, str(ROOT / "scripts/release/build_bundle.py"), "--baseline",
                                "--version", "11", "--label", "test", "--created", "2026-10-20T00:00:00Z",
                                "--out", str(out)], env=self.env, capture_output=True, text=True)
        self.assertEqual(build.returncode, 0, build.stderr)
        body = json.loads((out / "bundle-11.unsigned.json").read_bytes())
        comps = [(c, (out / "blobs/sha256" / c["sha256"]).read_bytes()) for c in body["components"]]
        profiles = {"schema": "swarmhub/profiles/1", "profiles": [
            {"name": "default", "coding_order": "claude,codex,hermes", "skills": None},
            {"name": "coder_2", "coding_order": "codex", "skills": None}]}
        status = self.transport(self.stage(11, comps, profiles=profiles), profiles)
        self.assertEqual(status["state"], "pending_confirm")
        self.assertFalse(self.live("swarmhub-coding").exists())
        # P4b never confirms. This explicit box-local confirm exercises the updater's existing decision-2 gate.
        code, status = self.real("--max-wait", "0", "apply", "--version", "11")
        self.assertEqual((code, status["state"]), (0, "current"), status["detail"])
        for profile in profiles["profiles"]:
            for skill in (c for c in body["components"] if c["kind"] == "skill"):
                slug = profile["coding_order"].replace(",", "-") if skill["name"] == "swarmhub-coding" else "any-order"
                golden = RENDERS / skill["name"] / profile["name"]
                self.assertEqual((self.live(skill["name"], profile["name"]) / "SKILL.md").read_bytes(),
                                 (golden / slug / "SKILL.md").read_bytes())
                for reference in (golden / "files").rglob("*"):
                    if reference.is_file():
                        self.assertEqual((self.live(skill["name"], profile["name"]) /
                                          reference.relative_to(golden / "files")).read_bytes(), reference.read_bytes())
        self.assertTrue(status["reload_pending"])
        self.assertEqual(status["profiles"]["coder_2"]["variants"], {"swarmhub-coding": "codex"})
        self.assert_confined()

    def test_altered_archive_refused_last_good_and_previous_kept(self):
        _, comps = self.release("v1")
        first = self.stage(11, comps)
        self.transport(first)
        self.assertEqual(self.real("--max-wait", "0", "apply", "--version", "11")[0], 0)
        before = {p: box_snapshot(self.category(p)) for p in ("default", "coder_2")}
        _, changed_comps = self.release("v2", version="1.1.0", note="tamper")
        candidate = self.stage(12, changed_comps, seq=6)

        def alter(files):
            path = "blobs/sha256/" + changed_comps[0][0]["sha256"]
            data = bytearray(files[path])
            data[600] ^= 1
            files[path] = bytes(data)

        status = self.transport(candidate, mutate=alter)
        self.assertEqual((status["last"]["verdict"], status["last"]["reason"]), ("reject", "blob_hash_mismatch"))
        self.assertEqual(status["applied_bundle_version"], 11)
        self.assertEqual({p: box_snapshot(self.category(p)) for p in before}, before)
        self.assert_confined()

    def test_same_bundle_rerenders_changed_coding_order_and_preserves_other_profiles(self):
        _, comps = self.release("v1")
        self.transport(self.stage(11, comps))
        self.assertEqual(self.real("--max-wait", "0", "apply", "--version", "11")[0], 0)
        old_default = box_snapshot(self.category())
        profiles = {"schema": "swarmhub/profiles/1", "profiles": [
            {"name": "coder_2", "coding_order": "hermes", "skills": ["swarmhub-coding"]}]}
        status = self.transport(self.stage(11, comps), profiles)
        self.assertEqual(status["state"], "current", status["detail"])
        self.assertIsNone(status["pending_confirm"])
        self.assertEqual(status["profiles"]["coder_2"]["variants"]["swarmhub-coding"], "hermes")
        self.assertIn("Order hermes", (self.live("swarmhub-coding", "coder_2") / "SKILL.md").read_text())
        self.assertEqual(box_snapshot(self.category()), old_default)
        saved = json.loads((self.state / "profiles.json").read_bytes())["profiles"]
        self.assertEqual({p["name"] for p in saved}, {"default", "coder_2"})
        self.assertIn("swarmhub-messages", next(p["skills"] for p in saved if p["name"] == "coder_2"))
        self.assert_confined()

    def test_status_variant_is_not_reused_after_live_bytes_change(self):
        _, comps = self.release("v1")
        self.transport(self.stage(11, comps))
        self.real("--max-wait", "0", "apply", "--version", "11")
        path = self.live("swarmhub-coding", "coder_2") / "SKILL.md"
        path.write_text(path.read_text() + "manual edit\n")
        _, status = self.real("check")
        self.assertNotIn("swarmhub-coding", status["profiles"]["coder_2"]["variants"])
        self.assert_confined()

    def test_same_verified_archives_install_into_an_additional_profile(self):
        _, comps = self.release("v1")
        first = {"schema": "swarmhub/profiles/1", "profiles": [PROFILES_DOC["profiles"][0]]}
        self.transport(self.stage(11, comps), first)
        self.assertEqual(self.real("--max-wait", "0", "apply", "--version", "11")[0], 0)
        self.assertFalse(self.live("swarmhub-coding", "coder_2").exists())
        default_before = box_snapshot(self.category())
        second = {"schema": "swarmhub/profiles/1", "profiles": [PROFILES_DOC["profiles"][1]]}
        status = self.transport(self.stage(11, comps), second)
        self.assertEqual(status["state"], "current", status["detail"])
        self.assertIsNone(status["pending_confirm"])
        self.assertEqual(status["profiles"]["coder_2"]["advertised"]["swarmhub-coding"], "1.0.0")
        self.assertEqual(box_snapshot(self.category()), default_before)
        self.assert_confined()
