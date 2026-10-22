"""P4c: execute the Mac's version-bound command against isolated TEST-key updater states.

Swift tests cover the click/transport/UI and persisted regression record on the Mac. These Linux tests cover
the actual updater gate behind that command. No sockets, external hosts, real boxes or Hermes changes.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import CliCase, CODING, FEEDBACK, MESSAGES, ROOT, box_snapshot  # noqa: E402

# Stands in for a live swarmhub-messages copy's swarmctl: it records how the Mac's command called it.
RECEIVER_STUB = '''#!/usr/bin/env python3
import json, sys
with open(%r, "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\\n")
'''


class MacCodeConfirm(CliCase):
    def setUp(self):
        super().setUp()
        shutil.copytree(ROOT / "Resources/Updater/swarmhub_update", self.prefix / "swarmhub_update")
        (self.prefix / "bin").mkdir()
        self.launcher = self.prefix / "bin/swarmhub-update"
        shutil.copyfile(ROOT / "Resources/Updater/bin/swarmhub-update", self.launcher)
        self.launcher.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), XDG_STATE_HOME=str(self.home / ".local/state"),
                        HERMES_INSTALL_DIR=str(self.tmp / "no-hermes"), PYTHONDONTWRITEBYTECODE="1")
        self.before = box_snapshot(self.hermes / "hermes-agent")

    def command(self, version):
        source = (ROOT / "Sources/AgentApp/Updates/StagedInstall.swift").read_text()
        literal = re.search(r'static func confirmCommand\(version: Int64\) -> String \{ updater \+ "([^"]+)" \+ receiverCommand \}',
                            source)[1]
        receiver = re.search(r'static let receiverCommand = #"(.+)"#\n', source)[1]
        # Substitute only the fixed path for this isolated fixture's admin-style prefix, plus the numeric version.
        return str(self.launcher) + literal.replace(r"\(version)", str(version)) + receiver

    def confirm(self, version):
        result = subprocess.run(["/bin/sh", "-c", self.command(version)], env=self.env,
                                text=True, capture_output=True, timeout=90)
        self.assertTrue(result.stdout, result.stderr)
        return result.returncode, json.loads(result.stdout)

    def pending_release(self, version=11, component_version="1.0.0", seq=5):
        _, components = self.release("v%d" % version, version=component_version,
                                     deps={FEEDBACK: [{"name": CODING, "min_version": component_version}]})
        code, status = self.update("apply", "--staged", str(self.stage(version, components, seq=seq)))
        self.assertEqual((code, status["state"]), (0, "pending_confirm"))
        self.assertIn(CODING, [row["name"] for row in status["pending_confirm"]["code"]])
        self.assertEqual(next(row["waits_for"] for row in status["pending_confirm"]["data"]
                              if row["name"] == FEEDBACK), [CODING])
        return status

    def assert_hermes_unchanged(self):
        self.assertEqual(box_snapshot(self.hermes / "hermes-agent"), self.before)

    def test_status_verify_and_check_never_confirm_code(self):
        self.pending_release()
        for command in ("status", "verify", "check", "check"):
            code, status = self.update(command)
            self.assertEqual(code, 0)
            if command != "verify":
                self.assertEqual(status["state"], "pending_confirm")
            self.assertFalse(self.live(CODING).exists())
            self.assertFalse(self.live(FEEDBACK).exists(), "dependent data waits alongside code")
        code, status = self.confirm(11)
        self.assertEqual((code, status["state"], status["confirmed_version"]), (0, "current", 11))
        self.assertEqual(self.live_version(CODING), "1.0.0")
        self.assertEqual(self.live_version(FEEDBACK), "1.0.0")
        self.assert_hermes_unchanged()

    def test_one_box_confirmation_cannot_confirm_another_box(self):
        self.pending_release()
        other = CliCase()
        other.setUp()
        self.addCleanup(other.doCleanups)
        _, components = other.release("other")
        self.assertEqual(other.update("apply", "--staged", str(other.stage(11, components)))[0], 0)
        other_before = box_snapshot(other.home)
        self.assertEqual(self.confirm(11)[0], 0)
        self.assertEqual(box_snapshot(other.home), other_before, "no write or confirmation on the other box")
        self.assertEqual(other.update("status")[1]["state"], "pending_confirm")
        self.assertFalse(other.live(CODING).exists())
        self.assert_hermes_unchanged()

    def test_click_for_n_refuses_n_plus_one_arriving_before_apply(self):
        self.pending_release()
        old_command = self.command(11)
        self.pending_release(12, "1.1.0", seq=6)
        code, status = self.confirm(11)
        self.assertEqual(self.command(11), old_command)
        self.assertEqual((code, status["last"]["reason"]), (65, "version_changed"))
        self.assertFalse(self.live(CODING).exists())
        self.assertNotEqual(status["confirmed_version"], 12)
        self.assertEqual(self.confirm(12)[0], 0)
        self.assertEqual(self.live_version(CODING), "1.1.0")
        self.assert_hermes_unchanged()

    def test_the_confirm_reinstalls_the_webhook_receiver_once_its_code_is_live(self):
        calls = self.tmp / "receiver-calls"
        _, components = self.release("v11", files={MESSAGES + "/scripts/swarmctl": RECEIVER_STUB % str(calls)})
        code, status = self.update("apply", "--staged", str(self.stage(11, components)))
        self.assertEqual((code, status["state"]), (0, "pending_confirm"))
        self.assertFalse((self.live(MESSAGES) / "scripts/swarmctl").exists(), "swarmhub-messages is code: it waits")
        code, status = self.confirm(12)
        self.assertEqual((code, status["last"]["reason"]), (65, "version_changed"))
        self.assertFalse(calls.exists(), "a refused confirm never reaches the receiver")
        code, status = self.confirm(11)  # stdout is still exactly the updater's one JSON status
        self.assertEqual((code, status["state"]), (0, "current"))
        self.assertEqual(calls.read_text().splitlines(), ['["webhook", "receiver", "install"]'],
                         "one install per box account, from the copy the confirm just made live")
        self.assert_hermes_unchanged()

    def test_a_deferred_confirm_installs_the_receiver_when_its_retry_lands(self):
        calls = self.tmp / "receiver-calls"
        _, components = self.release("v11", files={MESSAGES + "/scripts/swarmctl": RECEIVER_STUB % str(calls)})
        self.assertEqual(self.update("apply", "--staged", str(self.stage(11, components)))[0], 0)
        sleeper = self.start_sleeper()
        slot = self.code_job_slot(sleeper.pid)  # a busy box: the --max-wait 0 confirm defers
        code, status = self.confirm(11)
        self.assertEqual((code, status["state"], status["confirmed_version"]), (75, "deferred", 11))
        self.assertFalse(calls.exists(), "deferred: the code is not live, so the receiver step has not run")
        # What the Mac reads back and offers as a retry (BoxUpdateState.Confirmation): deferred, confirmed, not applied.
        code, status = self.update("status")
        self.assertEqual((status["state"], status["pending_confirm"], status["bundle"]["bundle_version"],
                          status["confirmed_version"]), ("deferred", None, 11, 11))
        self.assertNotEqual(status["applied_bundle_version"], 11)
        sleeper.kill()
        sleeper.wait()
        shutil.rmtree(str(slot))
        code, status = self.confirm(11)  # the retry is the same command
        self.assertEqual((code, status["state"], status["applied_bundle_version"]), (0, "current", 11))
        self.assertEqual(calls.read_text().splitlines(), ['["webhook", "receiver", "install"]'],
                         "the retry that lands the code installs the receiver once")
        self.assert_hermes_unchanged()
