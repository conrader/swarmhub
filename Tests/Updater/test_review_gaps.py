"""Regressions for the three reproduced cc56a3b review gaps; local TEST releases only."""

import errno
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import (CODING, FEEDBACK, MANAGER, MESSAGES, PROFILES, RELEASE, CliCase,  # noqa: E402
                          apply, box_snapshot, changed, component, index, stage)
from apply_fixtures import BoxCase  # noqa: E402


class Dependencies(CliCase):
    def test_held_code_holds_its_data_before_install(self):
        _, comps = self.release("v1")
        self.update("apply", "--staged", str(self.stage(11, comps)))
        self.update("apply")
        (self.state / "profiles.json").unlink()  # discovery cannot reconstruct a coding order
        plain = '---\nname: %s\nversion: 1.1.0\ndescription: "SwarmHub, v1.1.0"\n---\nData.\n' % FEEDBACK
        _, comps = self.release("v2", version="1.1.0", note="v2",
                                files={FEEDBACK + "/SKILL.md": plain},
                                deps={FEEDBACK: [{"name": CODING, "min_version": "1.1.0"}]})
        self.update("apply", "--staged", str(self.stage(12, comps, profiles=None)))
        before = box_snapshot(str(self.live(FEEDBACK)))
        _, out = self.update("apply")
        self.assertEqual(box_snapshot(str(self.live(FEEDBACK))), before)
        self.assertEqual(out["components"][FEEDBACK]["version"], "1.0.0")
        self.assertIn("held", out["detail"])

    def test_load_failure_holds_direct_and_transitive_data_before_install(self):
        _, comps = self.release("v1")
        self.update("apply", "--staged", str(self.stage(11, comps)))
        self.assertEqual(self.update("apply")[1]["state"], "current")
        deps = {FEEDBACK: [{"name": CODING, "min_version": "1.1.0"}],
                MANAGER: [{"name": FEEDBACK, "min_version": "1.1.0"}]}
        # Valid signed code archive, but its skill cannot load (missing advertised version).
        bad = '---\nname: %s\nversion: 1.1.0\ndescription: "No version here."\n---\nCode.\n' % CODING
        _, comps = self.release("bad", version="1.1.0", note="v2", deps=deps,
                                files={CODING + "/SKILL.md": bad})
        comps += [component("config", "dependent-notes", "1.0.0", {"notes.md": (b"new\n", 0o644)},
                            [{"name": MANAGER, "min_version": "1.1.0"}]),
                  component("config", "independent", "1.0.0", {"policy.json": (b"{}\n", 0o644)})]
        self.assertEqual(self.update("apply", "--staged", str(self.stage(12, comps)))[1]["state"],
                         "pending_confirm")
        before = {(p.name, n): box_snapshot(str(self.live(n, p.name)))
                  for p in PROFILES for n in (CODING, FEEDBACK, MANAGER)}
        real = apply.apply
        with mock.patch.object(apply, "apply", wraps=real) as install:
            code, out = self.update("apply")
        self.assertEqual((code, out["state"]), (70, "failed"))
        self.assertIn("does not advertise", out["detail"])
        for call in install.call_args_list:
            self.assertFalse({s.name for s in call.args[2]} & {CODING, FEEDBACK, MANAGER})
        for (profile, name), snapshot in before.items():
            self.assertEqual(box_snapshot(str(self.live(name, profile))), snapshot, (profile, name))
            self.assertEqual(out["components"][name]["version"], "1.0.0")
        self.assertNotIn("dependent-notes", out["components"])
        self.assertIn("independent", out["components"])


class StoredFloors(CliCase):
    def pending(self):
        _, comps = self.release("v1")
        self.update("apply", "--staged", str(self.stage(11, comps)))
        self.update("apply")
        _, comps = self.release("v2", version="1.1.0", note="v2")
        self.assertEqual(self.update("apply", "--staged", str(self.stage(12, comps, seq=6)))[1]["state"],
                         "pending_confirm")

    def test_withdrawn_bundle_cannot_replay_its_stored_index_below_saved_floor(self):
        self.pending()
        folder = self.stage(13, [], seq=7)
        (folder / "channels/stable.json").write_bytes(index([], 7))  # signed withdrawal of pending 12
        self.assertEqual(self.update("apply", "--staged", str(folder))[1]["last"]["reason"], "no_compatible_line")
        self.assertEqual(self.floors()["index_seq"], 7)
        self.assertEqual((self.state / "bundles/12/index.json").exists(), True)
        before = box_snapshot(str(self.hermes))
        for args in (("verify",), ("check",), ("apply",), ("apply", "--version", "12"),
                     ("pin", "clear")):
            with self.subTest(args=args):
                code, out = self.update(*args)
                verdict = out if args[0] == "verify" else out["last"]
                self.assertEqual((code, verdict.get("reason")), (65, "index_rollback"))
                self.assertEqual(changed(before, box_snapshot(str(self.hermes))), [])

    def test_every_stored_verification_path_enforces_revocation(self):
        self.pending()
        self.write_pins(revoked=[RELEASE])
        before = box_snapshot(str(self.hermes))
        for args in (("verify",), ("check",), ("apply",), ("pin", "clear")):
            with self.subTest(args=args):
                code, out = self.update(*args)
                verdict = out if args[0] == "verify" else out["last"]
                self.assertEqual((code, verdict["reason"]), (65, "key_revoked"))
                self.assertEqual(changed(before, box_snapshot(str(self.hermes))), [])


class Crash(BaseException):
    """Simulated process death bypasses ordinary error handlers."""


class ReloadRecovery(BoxCase):
    def test_rollback_recovery_does_not_report_an_unsaved_reload_flag(self):
        self.recovery_save_failure(committed=False)

    def test_committed_recovery_does_not_report_an_unsaved_reload_flag(self):
        self.recovery_save_failure(committed=True)

    def recovery_save_failure(self, committed):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", plugin="p2")
        self.apply(v1, PROFILES[:1])
        apply.clear_reload_pending(str(self.state), "default")
        real = apply._write_json

        def die(path, value, mode):
            if value.get("state") == "committed":
                if committed:
                    real(path, value, mode)
                raise Crash()
            return real(path, value, mode)

        with mock.patch.object(apply, "_write_json", side_effect=die):
            with self.assertRaises(Crash):
                self.apply(v2, PROFILES[:1])
        self.assert_live(v2)
        for failure in ("write", "fsync"):
            def fail_save(path, value, mode):
                if path == apply.record_path(str(self.state), "default"):
                    if failure == "fsync":
                        with mock.patch.object(apply, "_fsync_dir", side_effect=OSError(errno.EIO, "fsync failed")):
                            return real(path, value, mode)
                    raise OSError(errno.ENOSPC, "record save failed")
                return real(path, value, mode)

            with self.subTest(failure=failure), mock.patch.object(apply, "_write_json", side_effect=fail_save):
                result = self.apply(v1, PROFILES[:1])[0]
            self.assertEqual(result.status, "recovery_pending")
            self.assertFalse(result.reload_pending, result.detail)
            self.assertIn("reload_pending", result.detail)
            self.assertTrue(list(Path(stage.work_dir(str(self.category()))).glob("txn-*")))
        # A successful retry durably records the flag before returning it, then clears the journal.
        category = str(self.category())
        self.assertEqual(apply.recover(category, str(self.state), "default"), 1)
        self.assertTrue(apply.read_record(str(self.state), "default")["reload_pending"])
        self.assert_live(v2 if committed else v1)
        self.assert_no_transactions()


if __name__ == "__main__":
    unittest.main()
