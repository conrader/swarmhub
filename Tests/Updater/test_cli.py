"""P2b: `swarmhub-update` commands and the decision-2 gate (CORE-PHASES.md P2b acceptance).

    python3 -m unittest discover -s Tests/Updater
"""

import ast
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_fixtures import HERMES as HERMES_FIXTURE  # noqa: E402
from cli_fixtures import (CODING, FEEDBACK, MANAGER, MESSAGES, PROFILES, ROOT, CliCase, apply,  # noqa: E402
                          box_snapshot, changed, component, stage)

PACKAGE = ROOT / "Resources/Updater/swarmhub_update"
LAUNCHER = ROOT / "Resources/Updater/bin/swarmhub-update"
SWARMCTL = ROOT / "Resources/Skills/swarmhub-messages/scripts/swarmctl"
NETWORK_MODULES = {"socket", "ssl", "http", "urllib", "ftplib", "smtplib", "asyncio", "xmlrpc", "socketserver",
                   "telnetlib", "poplib", "imaplib", "requests", "selectors", "webbrowser"}


class Flow(CliCase):
    def start(self):
        """Bundle 11 applied: data at once, code after the confirm."""
        v1, comps = self.release("v1")
        code, out = self.update("apply", "--staged", str(self.stage(11, comps)))
        self.assertEqual((code, out["state"]), (0, "pending_confirm"), out["detail"])
        code, out = self.update("apply", "--version", "11")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assert_live(v1)
        self.assert_live(v1, PROFILES[1])
        return v1

    def pending(self, out):
        return ([c["name"] for c in out["pending_confirm"]["code"]],
                {d["name"]: d["waits_for"] for d in out["pending_confirm"]["data"]})


class DecisionTwo(Flow):
    def test_code_never_applies_without_confirm_while_independent_data_does(self):
        v1 = self.start()
        v2, comps = self.release("v2", version="1.1.0", note="v2")
        code, out = self.update("apply", "--staged", str(self.stage(12, comps)))
        self.assertEqual((code, out["state"]), (0, "pending_confirm"))
        self.assertEqual(self.pending(out), ([CODING, MESSAGES], {}))
        self.assertEqual(self.live_version(FEEDBACK), "1.1.0")  # data skill
        self.assertEqual(self.live_version(MANAGER), "1.1.0")
        for profile in PROFILES:  # code skills untouched in every profile
            for skill in (CODING, MESSAGES):
                self.assertEqual(self.live_version(skill, profile.name), "1.0.0")
                self.assertEqual(self.expected(v1, skill, profile), stage.snapshot(str(self.live(skill, profile.name))))
        code, out = self.update("check")  # the timer path never confirms
        self.assertEqual((code, out["state"]), (0, "pending_confirm"))
        self.assertEqual(self.live_version(CODING), "1.0.0")
        code, out = self.update("apply")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assert_live(v2)
        self.assert_live(v2, PROFILES[1])
        self.assertIsNone(out["pending_confirm"])
        self.assertEqual(out["applied_bundle_version"], 12)
        self.assertEqual(out["components"][CODING]["version"], "1.1.0")
        # The applied version is what the live SKILL.md descriptions advertise, and what the status file says.
        self.assertEqual(out["profiles"]["default"]["advertised"],
                         {CODING: "1.1.0", FEEDBACK: "1.1.0", MANAGER: "1.1.0", MESSAGES: "1.1.0"})
        self.assertEqual(out["profiles"]["coder_2"]["advertised"], {CODING: "1.1.0", MESSAGES: "1.1.0"})
        self.assertEqual(self.status(), out)

    def test_data_requiring_pending_code_waits_and_applies_with_it(self):
        self.start()
        need_coding = [{"name": CODING, "min_version": "1.1.0"}]
        v2, comps = self.release("v2", version="1.1.0", note="v2", deps={FEEDBACK: need_coding})
        comps += [component("config", "box-notes", "1.0.0", {"notes.md": (b"needs coding 1.1\n", 0o644)},
                            need_coding),
                  component("config", "box-chain", "1.0.0", {"chain.md": (b"needs feedback 1.1\n", 0o644)},
                            [{"name": FEEDBACK, "min_version": "1.1.0"}]),  # transitive, through data
                  component("config", "box-policy", "1.0.0", {"policy.json": (b"{}\n", 0o644)})]
        code, out = self.update("apply", "--staged", str(self.stage(12, comps)))
        self.assertEqual((code, out["state"]), (0, "pending_confirm"), out["detail"])
        self.assertEqual(self.pending(out), ([CODING, MESSAGES],
                                             {FEEDBACK: [CODING], "box-notes": [CODING], "box-chain": [CODING]}))
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")
        self.assertEqual(self.live_version(MANAGER), "1.1.0")  # independent data
        self.assertIn("box-policy", out["components"])
        self.assertNotIn("box-notes", out["components"])
        code, out = self.update("apply", "--version", "12")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assert_live(v2)
        self.assertTrue({"box-notes", "box-chain", "box-policy"} <= set(out["components"]))

    def test_a_dependency_the_box_already_satisfies_does_not_hold_data_back(self):
        self.start()
        v2, comps = self.release("v2", version="1.1.0", note="v2",
                                 deps={FEEDBACK: [{"name": CODING, "min_version": "1.0.0"}]})
        code, out = self.update("apply", "--staged", str(self.stage(12, comps)))
        self.assertEqual(self.pending(out), ([CODING, MESSAGES], {}))
        self.assertEqual(self.live_version(FEEDBACK), "1.1.0")

    def test_data_never_lands_without_the_code_it_waits_for(self):
        v1 = self.start()
        need_coding = [{"name": CODING, "min_version": "1.1.0"}]
        _, comps = self.release("bad", version="1.1.0", note="v2", answer=41, deps={FEEDBACK: need_coding})
        comps.append(component("config", "box-notes", "1.0.0", {"notes.md": (b"x\n", 0o644)}, need_coding))
        self.update("apply", "--staged", str(self.stage(12, comps)))
        code, out = self.update("apply")  # confirmed, but the coding self-test fails
        self.assertEqual((code, out["state"]), (70, "failed"))
        self.assertIn("self-test", out["detail"])
        self.assert_live(v1, PROFILES[1])
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")
        self.assertNotIn("box-notes", out["components"])
        self.assertEqual(out["components"][CODING]["version"], "1.0.0")

    def test_one_confirmation_covers_one_bundle_version(self):
        self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2")
        self.update("apply", "--staged", str(self.stage(12, comps)))
        code, out = self.update("apply", "--version", "11")
        self.assertEqual((code, out["last"]["reason"]), (65, "version_changed"))
        self.assertEqual(self.live_version(CODING), "1.0.0")
        self.code_job_slot(self.start_sleeper().pid)  # confirm 12 while busy: deferred, confirmation kept
        code, out = self.update("apply", "--version", "12")
        self.assertEqual((code, out["state"], out["confirmed_version"]), (75, "deferred", 12))
        v3, comps = self.release("v3", version="1.2.0", note="v3")
        code, out = self.update("apply", "--staged", str(self.stage(13, comps, seq=6)))
        self.assertEqual(self.pending(out)[0], [CODING, MESSAGES])  # 13's code needs its own confirm
        self.assertEqual(self.live_version(CODING), "1.0.0")

    def test_busy_box_defers_then_check_applies(self):
        self.start()
        v2, comps = self.release("v2", files={FEEDBACK + "/notes.md": "data only\n"})
        sleeper = self.start_sleeper()
        slot = self.code_job_slot(sleeper.pid)
        code, out = self.update("apply", "--staged", str(self.stage(12, comps)))
        self.assertEqual((code, out["state"]), (75, "deferred"))
        self.assertFalse((self.live(FEEDBACK) / "notes.md").exists())
        sleeper.kill()
        sleeper.wait()
        shutil.rmtree(str(slot))
        code, out = self.update("check")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assert_live(v2)

    def test_tampered_archive_is_refused_and_nothing_changes(self):
        self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2")
        folder = self.stage(12, comps)
        blob = folder / "blobs/sha256" / comps[0][0]["sha256"]
        blob.write_bytes(blob.read_bytes()[:-1] + b"\1")
        before = box_snapshot(str(self.hermes))
        code, out = self.update("apply", "--staged", str(folder))
        self.assertEqual((code, out["last"]["reason"], out["state"]), (65, "blob_hash_mismatch", "current"))
        self.assertEqual(changed(before, box_snapshot(str(self.hermes))), [])
        self.assertEqual(out["applied_bundle_version"], 11)

    def test_skill_that_does_not_advertise_its_version_is_not_applied(self):
        self.start()
        skill_md = "---\nname: swarmhub-feedback\ndescription: \"No version here.\"\nversion: 1.1.0\n---\n\nText.\n"
        _, comps = self.release("v2", files={FEEDBACK + "/SKILL.md": skill_md})
        code, out = self.update("apply", "--staged", str(self.stage(12, comps)))
        self.assertEqual((code, out["state"]), (70, "failed"))
        self.assertIn("does not advertise", out["detail"])
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")

    def test_without_profiles_only_installed_skills_update_and_coding_orders_are_not_guessed(self):
        v1, comps = self.release("v1")
        skills, manager = v1
        apply.apply(str(self.hermes), str(self.state), skills, manager, PROFILES[:1], max_wait=0)  # app install
        apply.clear_reload_pending(str(self.state), "default")
        _, comps = self.release("v2", version="1.1.0", note="v2")
        code, out = self.update("apply", "--staged", str(self.stage(12, comps, profiles=None)))
        self.assertEqual(out["state"], "pending_confirm")
        self.assertEqual(self.live_version(MANAGER), "1.1.0")  # renders no coding order
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")  # does: held, not guessed
        self.assertIn("coding order unknown", out["detail"])
        self.assertFalse(self.category("coder_2").exists())  # discovery never installs a skill


class Commands(Flow):
    def test_status_is_readable_by_swarmctl(self):
        if importlib.util.find_spec("zoneinfo") is None:  # swarmctl (messages skill) needs it, the updater does not
            self.skipTest("swarmctl imports zoneinfo, which needs Python 3.9+; updater status is checked without it")
        env = dict(os.environ, HOME=str(self.home), PYTHONDONTWRITEBYTECODE="1")
        env.pop("XDG_STATE_HOME", None)

        def swarmctl():
            done = subprocess.run([sys.executable, "-B", str(SWARMCTL), "update-status"], env=env, cwd=str(self.tmp),
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            return json.loads(done.stdout)
        self.assertEqual(swarmctl()["state"], "unknown")
        self.start()
        before = (self.state / "status.json").read_bytes()
        self.assertEqual(swarmctl(), self.status())
        self.assertEqual(self.update("status"), (0, self.status()))
        self.assertEqual((self.state / "status.json").read_bytes(), before)  # both prints are read-only

    def test_verify_and_status_change_nothing(self):
        self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2")
        folder = self.stage(12, comps)
        before = box_snapshot(str(self.home))
        code, out = self.update("verify", "--staged", str(folder))
        self.assertEqual((code, out["verdict"], out["would_apply_now"]), (0, "accept", [FEEDBACK, MANAGER]))
        self.assertEqual([c["name"] for c in out["pending_confirm"]["code"]], [CODING, MESSAGES])
        self.assertEqual(self.update("verify")[1]["bundle_version"], 11)
        self.update("status")
        self.assertEqual(changed(before, box_snapshot(str(self.home))), [])

    def test_hermes_untouched_and_writes_stay_in_scope(self):
        before = box_snapshot(str(self.home))
        hermes_bytes = (self.hermes / "hermes-agent/gateway/platforms/api_server.py").read_bytes()
        self.start()
        _, comps = self.release("v2", version="1.1.0", note="v2", plugin="p2")
        self.update("apply", "--staged", str(self.stage(12, comps)))
        self.update("apply")
        self.update("pin", "previous")
        self.update("pin", "clear")
        allowed = (".hermes/skills/swarmhub/", ".hermes/profiles/coder_2/skills/swarmhub/",
                   ".local/state/swarmhub-update")
        outside = [p for p in changed(before, box_snapshot(str(self.home))) if not p.startswith(allowed)
                   and p not in (".hermes/skills/swarmhub", ".hermes/profiles/coder_2/skills",
                                 ".hermes/profiles/coder_2/skills/swarmhub", ".local", ".local/state")]
        self.assertEqual(outside, [])
        self.assertEqual((self.hermes / "hermes-agent/gateway/platforms/api_server.py").read_bytes(), hermes_bytes)
        self.assertEqual(hermes_bytes, HERMES_FIXTURE.read_bytes())
        self.assert_no_pycache()

    def test_nothing_to_fetch_changes_nothing(self):
        before = box_snapshot(str(self.hermes))
        code, out = self.update("check")  # no stored bundle; check never fetches: runtime as it was
        self.assertEqual((code, out["last"]["verdict"]), (0, "none"))
        self.assertIn("no stored bundle", out["last"]["detail"])
        self.start()
        before = box_snapshot(str(self.hermes))
        self.assertEqual(self.update("check")[1]["state"], "current")
        self.assertEqual(changed(before, box_snapshot(str(self.hermes))), [])

    def test_no_network_code(self):
        """Only fetch.py (P3a pull) opens connections; every other module and the launcher stay network-free."""
        sources = sorted(p for p in PACKAGE.glob("*.py") if p.name != "fetch.py") + [LAUNCHER]
        for path in sources:
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                names = []
                if isinstance(node, ast.Import):
                    names = [alias.name for alias in node.names]
                elif isinstance(node, ast.ImportFrom) and node.level == 0:
                    names = [node.module or ""]
                for name in names:
                    self.assertNotIn(name.split(".")[0], NETWORK_MODULES, "%s imports %s" % (path.name, name))

    def test_pin_holds_updates_and_previous_reverts_without_lowering_floors(self):
        self.start()
        v2, comps = self.release("v2", files={FEEDBACK + "/notes.md": "two\n"})
        self.update("apply", "--staged", str(self.stage(12, comps)))
        self.assert_live(v2)
        floors = self.floors()
        code, out = self.update("pin", "previous")
        self.assertEqual((code, out["state"]), (0, "pinned"), out["detail"])
        self.assertFalse((self.live(FEEDBACK) / "notes.md").exists())
        self.assertEqual(self.floors(), floors)
        v3, comps = self.release("v3", files={FEEDBACK + "/notes.md": "three\n"})
        code, out = self.update("apply", "--staged", str(self.stage(13, comps, seq=6)))
        self.assertEqual((code, out["state"]), (0, "pinned"))
        self.assertFalse((self.live(FEEDBACK) / "notes.md").exists())
        self.assertEqual(self.floors()["bundle_version"], 13)
        code, out = self.update("pin", "clear")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assert_live(v3)

    def test_another_run_holds_the_lock(self):
        import fcntl
        self.state.mkdir(parents=True)
        fd = os.open(str(self.state / "cli.lock"), os.O_CREAT | os.O_RDWR)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.assertEqual(self.update("check")[0], 75)

    def test_launcher_imports_only_its_own_prefix(self):
        prefix = self.tmp / "installed"
        shutil.copytree(str(PACKAGE), str(prefix / "swarmhub_update"))
        (prefix / "bin").mkdir()
        shutil.copy2(str(LAUNCHER), str(prefix / "bin/swarmhub-update"))
        poison = self.tmp / "poison/swarmhub_update"
        poison.mkdir(parents=True)
        (poison / "__init__.py").write_text("open(%r, 'w').close()\n" % str(self.tmp / "POISONED"))
        env = dict(os.environ, HOME=str(self.home), PYTHONPATH=str(poison.parent))
        env.pop("XDG_STATE_HOME", None)
        argv = ["--hermes-home", str(self.hermes), "--max-wait", "0"]

        def launch(*args, direct=True):
            command = ([str(prefix / "bin/swarmhub-update")] if direct
                       else [sys.executable, str(prefix / "bin/swarmhub-update")])
            done = subprocess.run(command + argv + list(args), env=env, capture_output=True, text=True, timeout=120)
            return done.returncode, json.loads(done.stdout)
        self.assertEqual(launch("check")[0], 78)  # no pins.json beside the launcher: fail closed
        shutil.copy2(str(self.pins_path), str(prefix / "pins.json"))
        _, comps = self.release("v1")
        code, out = launch("apply", "--staged", str(self.stage(11, comps)))
        self.assertEqual((code, out["state"]), (0, "pending_confirm"), out)
        self.assertEqual(out["pins"]["path"], str(prefix / "pins.json"))
        code, out = launch("apply", "--version", "11", direct=False)  # re-executes itself isolated
        self.assertEqual((code, out["state"]), (0, "current"), out)
        self.assertFalse((self.tmp / "POISONED").exists())
        self.assertEqual([str(p) for p in prefix.rglob("__pycache__")], [])

    def test_damaged_state_is_reported_not_fatal(self):
        self.start()
        (self.state / "profiles.json").write_text('{"schema": "swarmhub/profiles/1", "profiles": [{"name": "../x"}]}')
        _, comps = self.release("v2", files={FEEDBACK + "/notes.md": "two\n"})
        code, out = self.update("apply", "--staged", str(self.stage(12, comps, profiles=None)))
        self.assertEqual((code, out["state"]), (70, "failed"))
        self.assertIn("bad profile name", out["detail"])
        self.assertFalse((self.live(FEEDBACK) / "notes.md").exists())
        (self.state / "bundles/12/keys.json").write_text("not json")  # newer keys still verify and replace it
        code, out = self.update("apply", "--staged", str(self.stage(12, comps, seq=6, keys_version=3)))
        self.assertNotIn("error", out)
        self.assertEqual(self.floors()["keys_version"], 3)

    def test_malformed_or_blocking_state_files_never_hang_or_crash(self):
        self.start()
        deep = "[" * 100000 + "]" * 100000
        for name, text in (("status.json", deep), ("applied.json", deep), ("profiles/default.json", deep),
                           ("applied.json", '{"components": [], "pin": "yes", "confirmed_version": "11"}'),
                           ("config.json", '{"channel": 5, "install_id": ["x"], "hermes_version": {}}'),
                           ("latest.json", '{"bundle_version": 11, "manifest_sha256": 7}')):
            with self.subTest(name=name, text=text[:20]):
                (self.state / name).write_text(text)
                for argv in (("status",), ("check",), ("verify",)):
                    code, out = self.update(*argv)
                    self.assertNotIn("error", out, (argv, out))
        for name in ("status.json", "applied.json", "floors.json", "latest.json", "profiles/default.json"):
            with self.subTest(fifo=name):
                path = self.state / name
                path.unlink() if path.exists() else None
                os.mkfifo(str(path))
                done = subprocess.run([sys.executable, "-B", "-c", "import sys; sys.path.insert(0, %r); "
                                       "from swarmhub_update import cli; sys.exit(cli.main(sys.argv[1:], %r))"
                                       % (str(PACKAGE.parent), str(self.pins_path)),
                                       "--state-dir", str(self.state), "--hermes-home", str(self.hermes),
                                       "--max-wait", "0", "check"], capture_output=True, text=True, timeout=60)
                self.assertNotIn("Traceback", done.stderr)
                path.unlink()

    def test_clearing_a_pin_with_nothing_stored(self):
        self.assertEqual(self.update("pin", "current")[1]["state"], "pinned")
        code, out = self.update("pin", "clear")
        self.assertEqual((code, out["state"]), (0, "unknown"))

    def test_usage_errors(self):
        self.assertEqual(self.update()[0], 64)
        self.assertEqual(self.update("--pins", "x", "status")[0], 64)  # the pin file is not an option
        self.assertEqual(self.update("apply", "--staged", "x", "--version", "3")[0], 64)
        self.assertEqual(self.update("pin", "nothing")[0], 64)


if __name__ == "__main__":
    unittest.main()
