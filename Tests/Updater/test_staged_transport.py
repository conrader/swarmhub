"""P4b: run the Mac's actual box-side transport script against the isolated real updater launcher, TEST keys only.
Swift is unavailable on Linux: app tests verify construction/selection and this suite executes the script's bytes.
No servers, real boxes or update hosts; Hermes and everything outside skills/swarmhub + updater state stay intact.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import textwrap

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import (CliCase, MESSAGES, ROOT, PROFILES_DOC, box_snapshot, changed, component,  # noqa: E402
                          source_components)

MAC = ROOT / "Sources/AgentApp/Updates/StagedInstall.swift"
RENDERS = ROOT / "Tests/Fixtures/release-bundles/renders"
# Stands in for a live swarmhub-messages copy's swarmctl: it records how the transport called it.
RECEIVER_STUB = '''#!/usr/bin/env python3
import json, sys
with open(%r, "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\\n")
'''


def transport_command(files, profiles, updater, home, mutate_parts=None, profile="default", dev_modes=None):
    """Emulate stock POST /api/sessions' INSERT of system_prompt; instantiate the actual Swift shell literal.

    Stock Hermes 0.21.7 api_server.py _handle_create_session stores the supplied string verbatim in
    sessions.system_prompt, without a model turn. Only that existing API writes the carrier rows in the app.
    """
    source = MAC.read_text()
    literal = source.split('return """\n        python3 -I -B', 1)[1].split('\n        """', 1)[0]
    literal = textwrap.dedent('        python3 -I -B' + literal)
    files = dict(files, **{"profiles.json": json.dumps(profiles).encode()})
    payload = json.dumps({p: base64.b64encode(b).decode() for p, b in files.items()}).encode()
    parts = [payload[i:i + 49152] for i in range(0, len(payload), 49152)]
    hashes = ", ".join(repr(hashlib.sha256(p).hexdigest()) for p in parts)
    whole = hashlib.sha256(payload).hexdigest()
    prefix = "agentapp_update_bytes_TEST_"
    if mutate_parts:
        mutate_parts(parts)
    hermes_home = home / ".hermes"
    if profile != "default":
        hermes_home = hermes_home / "profiles" / profile
    hermes_home.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(hermes_home / "state.db") as db:
        db.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, system_prompt TEXT)")
        db.execute("DELETE FROM sessions")
        for i, part in enumerate(parts):
            if part is not None:
                db.execute("INSERT INTO sessions (id, system_prompt) VALUES (?, ?)",
                           (prefix + str(i), base64.b64encode(part).decode()))
    merge = textwrap.dedent(source.split('static let profileMerge = #"""\n', 1)[1].split('\n    """#', 1)[0])
    modes = "{" + ", ".join("'%s': %s" % (k, v) for k, v in sorted((dev_modes or {}).items())) + "}"
    receiver = source.split('static let receiverCommand = #"', 1)[1].split('"#\n', 1)[0]
    values = {"prefix": prefix, "hashes": hashes, "whole": whole, "managerProfile": profile, "updater": str(updater),
              "profileMerge": merge, "modes": modes, "receiverCommand": receiver}
    for name, value in values.items():
        literal = literal.replace('\\(' + name + ')', value)
    return literal + '\n'


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

    def transport(self, folder, profiles=None, mutate=None, mutate_parts=None, profile="default", expected_code=None,
                  dev_modes=None):
        manifest = json.loads(next((folder / "bundles").iterdir()).read_bytes())["signed"]
        wanted = {c["sha256"] for c in manifest["components"] if "box" in c["targets"]}
        files = {p.relative_to(folder).as_posix(): p.read_bytes() for p in folder.rglob("*")
                 if p.is_file() and p.name != "profiles.json" and ("sha256" not in p.parts or p.name in wanted)}
        self.assertTrue(all(not p.startswith("blobs/") or p.rsplit("/", 1)[1] in wanted for p in files))
        if mutate:
            mutate(files)
        rows = (profiles or PROFILES_DOC)["profiles"]
        command = transport_command(files, rows, self.launcher, self.home, mutate_parts, profile, dev_modes)
        # Model instructions have only a bounded script, IDs and hashes, regardless of archive bytes.
        self.assertLess(len(command), 32768)
        before_db = {p: p.read_bytes() for p in (self.home / ".hermes").rglob("state.db")}
        snapshot = box_snapshot(self.home)
        for path in before_db:
            for item in [path] + list(path.parents):
                if item == self.home:
                    break
                rel = item.relative_to(self.home).as_posix()
                self.original[rel] = snapshot[rel]
        result = subprocess.run(["/bin/sh"], input=command, env=self.env, text=True, capture_output=True, timeout=90)
        self.last_transport = result
        if expected_code is None:
            expected_code = 65 if mutate else 1 if mutate_parts else 0
        self.assertEqual(result.returncode, expected_code, result.stderr)
        receipt = "SWARMHUB_TRANSFER_OK:agentapp_update_bytes_TEST_"
        self.assertEqual(receipt in result.stdout.splitlines(), result.returncode == 0)
        self.assertEqual({p: p.read_bytes() for p in before_db}, before_db, "transport never writes Hermes DB")
        self.assertEqual(list(self.state.glob("mac-stage-*")), [])
        return self.real("status")[1]

    def updater_result(self):
        line = next(line for line in self.last_transport.stdout.splitlines()
                    if line.startswith("SWARMHUB_UPDATER_RESULT:agentapp_update_bytes_TEST_"))
        return json.loads(line.split("TEST_", 1)[1])

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
        result = self.updater_result()
        self.assertEqual(result["exit_code"], 65)
        self.assertEqual(json.loads(result["output"])["last"]["reason"], "blob_hash_mismatch")
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

    def test_large_archive_reaches_updater_without_model_copying_payload(self):
        # An actual uncompressed signed skill archive, larger than today's skill sources.
        data = ("# Reference\n" + "realistic skill documentation and examples\n" * 8500).encode()
        comp = component("skill", "swarmhub-feedback", "1.0.0", {
            "SKILL.md": (b"---\nname: swarmhub-feedback\ndescription: Installed by SwarmHub, v1.0.0.\nversion: 1.0.0\n---\n", 0o644),
            "references/guide.md": (data, 0o644)})
        self.assertGreaterEqual(len(comp[1]), 300_000)
        profiles = {"profiles": [{"name": "default", "coding_order": "codex", "skills": ["swarmhub-feedback"]}]}
        status = self.transport(self.stage(11, [comp]), profiles)
        self.assertEqual(status["state"], "current", status["detail"])
        self.assertEqual((self.live("swarmhub-feedback") / "references/guide.md").read_bytes(), data)
        self.assert_confined()

    def test_altered_or_missing_part_fails_before_updater_and_keeps_last_good(self):
        _, comps = self.release("v1")
        self.transport(self.stage(11, comps))
        self.real("--max-wait", "0", "apply", "--version", "11")
        before = {p: box_snapshot(self.category(p)) for p in ("default", "coder_2")}
        status_before = (self.state / "status.json").read_bytes()
        _, candidate = self.release("v2", version="1.1.0", note="candidate")
        folder = self.stage(12, candidate, seq=6)
        for change in (lambda parts: parts.__setitem__(0, b"altered"),
                       lambda parts: parts.__setitem__(0, None)):
            with self.subTest(change=change):
                self.transport(folder, mutate_parts=change)
                self.assertIn("SWARMHUB_TRANSFER_FAILED:agentapp_update_bytes_TEST_", self.last_transport.stdout)
                self.assertNotIn("SWARMHUB_UPDATER_RESULT:", self.last_transport.stdout)
                self.assertEqual((self.state / "status.json").read_bytes(), status_before)
                self.assertEqual({p: box_snapshot(self.category(p)) for p in before}, before)
        self.assert_confined()

    def test_carrier_uses_the_managers_profile_database(self):
        _, comps = self.release("v1")
        status = self.transport(self.stage(11, comps), profile="coder_2")
        self.assertEqual(status["state"], "pending_confirm")
        self.assert_confined()

    def test_uncheckpointed_wal_is_read_without_touching_any_live_sqlite_file(self):
        _, comps = self.release("v1")
        folder = self.stage(11, comps)
        files = {p.relative_to(folder).as_posix(): p.read_bytes() for p in folder.rglob("*")
                 if p.is_file() and p.name != "profiles.json"}
        command = transport_command(files, PROFILES_DOC["profiles"], self.launcher, self.home)
        with sqlite3.connect(self.home / ".hermes/state.db") as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA wal_autocheckpoint=0")
            # Keep committed carrier rows solely in the WAL while a gateway-style connection stays open.
            rows = db.execute("SELECT * FROM sessions").fetchall()
            db.execute("DELETE FROM sessions")
            db.commit()
            db.executemany("INSERT INTO sessions VALUES (?, ?)", rows)
            db.commit()
            before = box_snapshot(self.hermes)
            result = subprocess.run(["/bin/sh"], input=command, env=self.env, text=True, capture_output=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)
            after = box_snapshot(self.hermes)
            self.assertEqual({k: after[k] for k in before}, before, "includes DB, WAL, SHM and Hermes fixture")
        self.assertEqual(self.real("status")[1]["state"], "pending_confirm")
        self.assertEqual(list(self.state.glob("mac-stage-*")), [])

    def test_busy_updater_returns_deferred_reason_without_success_receipt(self):
        _, comps = self.release("v1")
        self.transport(self.stage(11, comps))
        self.real("--max-wait", "0", "apply", "--version", "11")
        _, comps = self.release("v2", files={"swarmhub-feedback/notes.md": "data only\n"})
        sleeper = self.start_sleeper()
        slot = self.code_job_slot(sleeper.pid)
        status = self.transport(self.stage(12, comps), expected_code=75)
        result = self.updater_result()
        self.assertEqual(result["exit_code"], 75)
        self.assertEqual(json.loads(result["output"])["state"], "deferred")
        self.assertEqual(json.loads(result["output"])["detail"], status["detail"])
        self.assertFalse((self.live("swarmhub-feedback") / "notes.md").exists())
        sleeper.kill()
        sleeper.wait()
        shutil.rmtree(slot.parent)
        self.assert_confined()

    def test_lock_deferral_returns_this_invocations_reason_despite_old_status(self):
        _, comps = self.release("v1")
        folder = self.stage(11, comps)
        self.transport(folder)
        before = (self.state / "status.json").read_bytes()
        with (self.state / "cli.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.transport(folder, expected_code=75)
        result = self.updater_result()
        self.assertEqual(result["exit_code"], 75)
        self.assertEqual(json.loads(result["output"]), {
            "state": "deferred", "detail": "another swarmhub-update run is active"})
        self.assertEqual((self.state / "status.json").read_bytes(), before)
        self.assert_confined()

    def test_snapshot_is_deleted_before_updater_executes(self):
        real = self.launcher.with_name("real-update")
        self.launcher.rename(real)
        self.launcher.write_text("#!/usr/bin/env python3\nimport os, pathlib\n"
                                 "state = pathlib.Path(os.environ['XDG_STATE_HOME']) / 'swarmhub-update'\n"
                                 "assert not list(state.rglob('carrier.db*'))\n"
                                 "os.execv(%r, [%r] + __import__('sys').argv[1:])\n" % (str(real), str(real)))
        self.launcher.chmod(0o755)
        _, comps = self.release("v1")
        self.transport(self.stage(11, comps))
        self.assert_confined()

    def test_snapshot_size_limit_and_invalid_sqlite_fail_closed_and_clean_up(self):
        _, comps = self.release("v1")
        folder = self.stage(11, comps)
        files = {p.relative_to(folder).as_posix(): p.read_bytes() for p in folder.rglob("*")
                 if p.is_file() and p.name != "profiles.json"}
        for kind in ("database", "combined-wal", "invalid-sqlite"):
            with self.subTest(kind=kind):
                command = transport_command(files, PROFILES_DOC["profiles"], self.launcher, self.home)
                database, wal = self.hermes / "state.db", self.hermes / "state.db-wal"
                wal.unlink(missing_ok=True)
                if kind == "database":
                    with database.open("ab") as out:
                        out.truncate(64 * 1024 * 1024 + 1)
                elif kind == "combined-wal":
                    with wal.open("wb") as out:
                        out.truncate(64 * 1024 * 1024 - database.stat().st_size + 1)
                else:
                    database.write_bytes(b"not sqlite")
                before = box_snapshot(self.hermes)
                result = subprocess.run(["/bin/sh"], input=command, env=self.env, text=True, capture_output=True, timeout=90)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("SWARMHUB_TRANSFER_FAILED:", result.stdout)
                if kind != "invalid-sqlite":
                    self.assertIn("64 MiB snapshot limit", result.stdout)
                self.assertNotIn("SWARMHUB_UPDATER_RESULT:", result.stdout)
                self.assertFalse((self.state / "status.json").exists())
                self.assertEqual(list(self.state.glob("mac-stage-*")), [])
                self.assertEqual(box_snapshot(self.hermes), before)
                database.unlink()
                wal.unlink(missing_ok=True)
        self.assert_no_pycache()

    def test_live_variants_use_skill_names_not_profile_names(self):
        from swarmhub_update import runner, stage
        category = self.tmp / "variant-names"
        category.mkdir()
        names = ["skill.with-dots", "UPPERCASE", "../outside", "a" * 65]
        record = {"variants": {}}
        for name in names[:2]:
            (category / name).mkdir()
            (category / name / "SKILL.md").write_text("test")
        for name in names:
            record["variants"][name] = {"value": "codex", "tree": stage.tree_digest(str(category / name))}
        self.assertEqual(runner._live_variants(record, str(category)), {"skill.with-dots": "codex"})

    def test_a_request_for_one_profile_keeps_another_profiles_dev_mode_and_edit(self):
        """Skill dev mode: the default bot turned it on after its last request and edited a skill. A signed install for
        coder_2 alone carries the app's map, so the merged profiles.json keeps default's dev_mode and the edit stays."""
        _, comps = self.release("v1")
        self.transport(self.stage(11, comps))
        self.assertEqual(self.real("--max-wait", "0", "apply", "--version", "11")[0], 0)
        skill_md = self.live("swarmhub-feedback") / "SKILL.md"
        skill_md.write_text(skill_md.read_text() + "Edited on the box.\n")
        _, comps = self.release("v2", version="1.1.0", note="v2")
        only_b = {"schema": "swarmhub/profiles/1", "profiles": [PROFILES_DOC["profiles"][1]]}
        self.transport(self.stage(12, comps), only_b, dev_modes={"default": True, "coder_2": False})
        code, status = self.real("--max-wait", "0", "apply", "--version", "12")
        self.assertEqual((code, status["state"]), (0, "current"), status["detail"])
        self.assertIn("Edited on the box.", skill_md.read_text())
        self.assertEqual(status["profiles"]["default"]["modified"], ["swarmhub-feedback"])
        self.assertEqual(status["profiles"]["coder_2"]["advertised"]["swarmhub-coding"], "1.1.0")
        saved = {p["name"]: p for p in json.loads((self.state / "profiles.json").read_bytes())["profiles"]}
        self.assertIs(saved["default"].get("dev_mode"), True)
        self.assertNotIn("dev_mode", saved["coder_2"])

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

    def test_a_staged_install_reinstalls_the_webhook_receiver_from_a_live_copy_only_after_success(self):
        calls = self.tmp / "receiver-calls"
        stub = {MESSAGES + "/scripts/swarmctl": RECEIVER_STUB % str(calls)}
        _, comps = self.release("v1", files=stub)
        self.assertEqual(self.transport(self.stage(11, comps))["state"], "pending_confirm")
        self.assertFalse(calls.exists(), "no live swarmhub-messages copy yet: nothing to run")
        self.assertEqual(self.real("--max-wait", "0", "apply", "--version", "11")[0], 0)
        self.transport(self.stage(11, comps))
        self.assertEqual(calls.read_text().splitlines(), ['["webhook", "receiver", "install"]'],
                         "one install per box account, after the updater exited 0")
        calls.unlink()
        _, changed_comps = self.release("v2", version="1.1.0", note="tamper", files=stub)

        def alter(files):
            path = "blobs/sha256/" + changed_comps[0][0]["sha256"]
            data = bytearray(files[path])
            data[600] ^= 1
            files[path] = bytes(data)
        self.transport(self.stage(12, changed_comps, seq=6), mutate=alter)
        self.assertEqual(self.updater_result()["exit_code"], 65)
        self.assertFalse(calls.exists(), "a refused transfer never reaches the receiver")
        self.assert_confined()
