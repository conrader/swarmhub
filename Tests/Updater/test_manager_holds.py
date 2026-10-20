"""Manager input and cross-profile hold regressions; signed TEST bundles in temp boxes only."""

import copy
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import (CODING, FEEDBACK, MANAGER, PROMPTS, PROFILES, PROFILES_DOC, CliCase,  # noqa: E402
                          apply, box_snapshot, component)
from swarmhub_update import runner  # noqa: E402

NEW_TEXT = "NEW MANAGER TEXT for {{MANAGER}}.\n"


class ManagerInputs(CliCase):
    def test_blocked_prompts_use_installed_text_in_changed_and_rerendered_skills(self):
        _, baseline = self.release("v1")
        self.assertEqual(self.update("apply", "--staged", str(self.stage(11, baseline)))[0], 0)
        self.assertEqual(self.update("apply")[1]["state"], "current")
        manager_before = box_snapshot(str(self.live(MANAGER)))
        feedback = ('---\nname: %s\nversion: 1.1.0\n'
                    'description: "SwarmHub, v1.1.0"\n---\n{{MANAGER_TEXT}}\n' % FEEDBACK)
        for number, blocker in enumerate(("failed", "held", "dropped"), 12):
            with self.subTest(blocker=blocker):
                files = {FEEDBACK + "/SKILL.md": feedback,
                         FEEDBACK + "/scripts/run": "#!/bin/sh\nexit 0\n"}
                if blocker == "failed":
                    files[CODING + "/SKILL.md"] = (
                        '---\nname: %s\nversion: 1.1.0\ndescription: No advertised version\n---\n'
                        '{{CODING_ORDER}}\n' % CODING)
                _, updates = self.release(blocker, version="1.1.0", files=files)
                # Keep the manager component identical: only the prompt change requests its re-render.
                updates = [c for c in updates if c[0]["name"] not in (MANAGER, PROMPTS)]
                updates += [c for c in baseline if c[0]["name"] == MANAGER]
                updates += [component("config", "prompt-bridge", "1.1.0", {"notes.md": (b"bridge\n", 0o644)},
                                      [{"name": CODING, "min_version": "1.1.0"}]),
                            component("config", PROMPTS, "1.1.0", {"manager-hermes.md": (NEW_TEXT.encode(), 0o644)},
                                      [{"name": "prompt-bridge", "min_version": "1.1.0"}])]
                profiles = copy.deepcopy(PROFILES_DOC)
                if blocker == "dropped":
                    for profile in profiles["profiles"]:
                        profile["skills"] = [FEEDBACK, MANAGER]
                # Restore the baseline applied record and live trees between subcases.
                if number > 12:
                    self.wipe_state()
                    self.update("apply", "--staged", str(self.stage(11, baseline)))
                    self.assertEqual(self.update("apply")[1]["state"], "current")
                self.assertEqual(self.update("apply", "--staged",
                                             str(self.stage(number, updates, profiles=profiles)))[0], 0)
                # Exercise the runner's mixed known/unknown profile inputs; staged metadata requires known orders.
                entries = copy.deepcopy(profiles["profiles"])
                if blocker == "held":
                    entries[0]["coding_order"] = None
                with mock.patch.object(runner, "profiles_for", return_value=entries), \
                        mock.patch.object(apply, "apply", wraps=apply.apply) as install:
                    code, out = self.update("apply")
                self.assertEqual((code, out["state"]), (70, "failed"), out["detail"])
                self.assertIn("unavailable before install", out["detail"])
                self.assertTrue(install.called)
                for call in install.call_args_list:
                    self.assertEqual(call.args[3], "You manage {{MANAGER}}. Keys in {{MANAGER_ENV}}.\n")
                text = (self.live(FEEDBACK) / "SKILL.md").read_text()
                self.assertIn("You manage default.", text)
                self.assertNotIn("NEW MANAGER TEXT", text)
                self.assertEqual(self.live_version(FEEDBACK), "1.1.0")
                self.assertEqual(out["components"][FEEDBACK]["version"], "1.1.0")
                self.assertEqual(box_snapshot(str(self.live(MANAGER))), manager_before)
                self.assertEqual(out["components"][PROMPTS]["version"], "1.0.0")
                self.assertEqual(out["components"][CODING]["version"], "1.0.0")
                self.assertNotIn("prompt-bridge", out["components"])

    def test_blocked_prompts_without_installed_text_cannot_render_consumers(self):
        files = {CODING + "/SKILL.md": '---\nname: %s\nversion: 1.0.0\n'
                 'description: Missing advertised version\n---\nCode.\n' % CODING}
        _, comps = self.release("fresh", files=files,
                                deps={PROMPTS: [{"name": CODING, "min_version": "1.0.0"}]})
        self.update("apply", "--staged", str(self.stage(11, comps)))
        code, out = self.update("apply")
        self.assertEqual((code, out["state"]), (70, "failed"))
        self.assertIn("no applied manager-prompts", out["detail"])
        self.assertFalse(self.live(MANAGER).exists())
        self.assertNotIn(PROMPTS, out["components"])
        self.assertNotIn(MANAGER, out["components"])


class ProfileHolds(CliCase):
    def test_rerendered_manager_obeys_the_same_cross_profile_hold(self):
        manager = ('---\nname: %s\nversion: 1.0.0\ndescription: "SwarmHub, v1.0.0"\n---\n'
                   '{{CODING_ORDER}}\n{{MANAGER_TEXT}}\n' % MANAGER)
        _, baseline = self.release("v1", files={MANAGER + "/SKILL.md": manager})
        profiles = copy.deepcopy(PROFILES_DOC)
        profiles["profiles"][1]["skills"].append(MANAGER)
        self.update("apply", "--staged", str(self.stage(11, baseline, profiles=profiles)))
        self.assertEqual(self.update("apply")[1]["state"], "current")
        before = {p.name: box_snapshot(str(self.live(MANAGER, p.name))) for p in PROFILES}
        updates = [c for c in baseline if c[0]["name"] != PROMPTS]
        updates.append(component("config", PROMPTS, "1.1.0", {"manager-hermes.md": (NEW_TEXT.encode(), 0o644)}))
        entries = copy.deepcopy(profiles["profiles"])
        entries[0]["coding_order"] = None
        with mock.patch.object(runner, "profiles_for", return_value=entries):
            code, out = self.update("apply", "--staged", str(self.stage(12, updates, profiles=profiles)))
        self.assertEqual((code, out["state"]), (0, "held"), out["detail"])
        self.assertEqual(out["components"][PROMPTS]["version"], "1.1.0")
        for profile, snapshot in before.items():
            self.assertEqual(box_snapshot(str(self.live(MANAGER, profile))), snapshot, profile)

    def test_unknown_order_in_one_profile_holds_skill_in_every_profile(self):
        _, baseline = self.release("v1")
        self.update("apply", "--staged", str(self.stage(11, baseline)))
        self.assertEqual(self.update("apply")[1]["state"], "current")
        before = {p.name: box_snapshot(str(self.live(CODING, p.name))) for p in PROFILES}
        _, updates = self.release("v2", version="1.1.0", note="v2")
        profiles = copy.deepcopy(PROFILES_DOC)
        self.update("apply", "--staged", str(self.stage(12, updates, profiles=profiles)))
        entries = profiles["profiles"]
        entries[0]["coding_order"] = None
        with mock.patch.object(runner, "profiles_for", return_value=entries):
            for command in ("apply", "check"):
                code, out = self.update(command)
                self.assertEqual((code, out["state"]), (0, "held"), out["detail"])
                self.assertIn("coding order unknown", out["detail"])
                for profile, snapshot in before.items():
                    self.assertEqual(box_snapshot(str(self.live(CODING, profile))), snapshot, profile)
                self.assertEqual(out["components"][CODING]["version"], "1.0.0")
        # Supplying the missing order releases the box-wide hold on the next check.
        self.assertEqual(self.update("check")[1]["state"], "current")
        for profile in before:
            self.assertEqual(self.live_version(CODING, profile), "1.1.0")


if __name__ == "__main__":
    unittest.main()
