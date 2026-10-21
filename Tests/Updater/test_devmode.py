"""Skill dev mode in the box updater (devmode.py; the Mac app's per-bot toggle carried as `dev_mode` in profiles.json).

While a profile's dev mode is on, the updater keeps a skill the bot modified on its box, still updates the ones it did
not, reports the kept ones as `modified`, and never counts them as failures. `reset` (Reset to bundled) overwrites one
skill for one request and is never persisted. Dev mode off: a locally modified skill is overwritten exactly as before.

    python3 -m unittest discover -s Tests/Updater
"""

from collections import namedtuple
import json
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import (CODING, FEEDBACK, MANAGER, MESSAGES, PROFILES, PROFILES_DOC, CliCase, apply,  # noqa: E402
                          stage)
from swarmhub_update import devmode  # noqa: E402

DEV = [stage.Profile("default", PROFILES[0].coding_order, None, True), PROFILES[1]]
DEV_DOC = {"schema": PROFILES_DOC["schema"],
           "profiles": [dict(PROFILES_DOC["profiles"][0], dev_mode=True), PROFILES_DOC["profiles"][1]]}
ALL = (CODING, FEEDBACK, MANAGER, MESSAGES)
# The same files and digest are pinned in Tests/AgentAppTests/SkillDevModeTests.swift (SkillDevMode.contentDigest).
VECTOR_FILES = [("SKILL.md", "---\nname: demo\n---\nhello\n"), ("scripts/run", "#!/bin/sh\necho hi\n"),
                ("references/a.md", "ä\n")]
VECTOR = "643ff4d5ea625af5d62622e7e8779dd16e7010057e5ffcaf39496dabad96728c"
File = namedtuple("File", "path content")


class DevCase(CliCase):
    def edit(self, skill, profile="default"):
        path = self.live(skill, profile) / "SKILL.md"
        path.write_text(path.read_text() + "Edited on the box by the bot.\n")
        return path.read_text()

    def results(self, source, profiles):
        return {r.profile: r for r in self.apply(source, profiles)}

    def override(self, skill, profile="default"):
        folder = Path(devmode.overrides_dir(str(self.hermes), profile, skill))
        folder.mkdir(parents=True)
        (folder / "notes.md").write_text("the bot's working copy\n")
        return folder

    def snapshot(self, skill, profile="default"):
        return stage.snapshot(str(self.live(skill, profile)))

    def recorded(self, skill, profile="default"):
        return apply.read_record(str(self.state), profile)["skills"][skill]


class Engine(DevCase):
    def test_dev_mode_off_still_overwrites_a_locally_modified_skill(self):
        """REGRESSION: with dev mode off an edit (even with an override folder) is replaced, and nothing is recorded."""
        self.apply(self.source("v1"))
        self.edit(FEEDBACK)
        self.override(FEEDBACK)
        v2 = self.source("v2", version="1.1.0", note="v2")
        self.assertEqual(self.results(v2, PROFILES)["default"].status, "applied")
        self.assert_live(v2)
        self.assertEqual(self.recorded(FEEDBACK), "1.1.0")
        self.assertFalse((self.hermes / "swarmhub/dev-baseline").exists())

    def test_dev_mode_keeps_a_modified_skill_and_still_updates_the_unmodified_ones(self):
        self.apply(self.source("v1"), DEV)
        for name in ALL:  # a fresh install records what it wrote
            self.assertEqual(devmode.read_baseline(str(self.hermes), "default", name),
                             devmode.content_digest(str(self.live(name))), name)
        edited = self.edit(FEEDBACK)
        v2 = self.source("v2", version="1.1.0", note="v2")
        result = self.results(v2, DEV)["default"]
        self.assertEqual(result.status, "applied", result.detail)
        self.assertEqual((self.live(FEEDBACK) / "SKILL.md").read_text(), edited)
        self.assertEqual(self.recorded(FEEDBACK), "1.0.0", "a kept skill keeps its recorded version")
        for name in (CODING, MANAGER, MESSAGES):
            self.assertEqual(self.snapshot(name), self.expected(v2, name), name)
            self.assertEqual(self.recorded(name), "1.1.0")
        self.assert_live(v2, PROFILES[1])  # coder_2 is not in dev mode
        self.assert_no_transactions()

    def test_an_override_folder_keeps_the_skill_even_when_unchanged(self):
        v1 = self.source("v1")
        self.apply(v1, DEV)
        self.override(MANAGER)
        v2 = self.source("v2", version="1.1.0", note="v2")
        self.assertEqual(self.results(v2, DEV)["default"].status, "applied")
        self.assertEqual(self.snapshot(MANAGER), self.expected(v1, MANAGER))
        self.assertEqual(self.snapshot(CODING), self.expected(v2, CODING))

    def test_without_a_baseline_a_differing_skill_is_kept(self):
        v1 = self.source("v1")
        self.apply(v1)  # installed while dev mode was off: no baseline, and this engine run binds no tree
        result = self.results(self.source("v2", version="1.1.0", note="v2"), DEV)["default"]
        self.assertEqual(result.status, "unchanged", result.detail)
        self.assert_live(v1)

    def test_a_current_skill_establishes_its_baseline_and_then_updates(self):
        v1 = self.source("v1")
        self.apply(v1)
        self.assertEqual(self.results(v1, DEV)["default"].status, "unchanged")  # identical to the bundled copy
        v2 = self.source("v2", version="1.1.0", note="v2")
        self.assertEqual(self.results(v2, DEV)["default"].status, "applied")
        self.assert_live(v2)

    def test_reset_to_bundled_overwrites_removes_the_override_and_records_a_baseline(self):
        self.apply(self.source("v1"), DEV)
        self.edit(FEEDBACK)
        folder = self.override(FEEDBACK)
        v2 = self.source("v2", version="1.1.0", note="v2")
        reset = [DEV[0]._replace(reset=(FEEDBACK,)), DEV[1]]
        self.assertEqual(self.results(v2, reset)["default"].status, "applied")
        self.assertEqual(self.snapshot(FEEDBACK), self.expected(v2, FEEDBACK))
        self.assertFalse(folder.exists())
        self.assertEqual(devmode.read_baseline(str(self.hermes), "default", FEEDBACK),
                         devmode.content_digest(str(self.live(FEEDBACK))))
        self.assertTrue(folder.parent.is_dir(), "only the skill's own override folder goes")

    def test_a_deferred_reset_keeps_the_override(self):
        self.apply(self.source("v1"), DEV)
        self.edit(FEEDBACK)
        folder = self.override(FEEDBACK)
        self.start_sleeper()
        self.code_job_slot(os.getpid())  # box busy: the run defers and nothing live changes
        reset = [DEV[0]._replace(reset=(FEEDBACK,))]
        self.assertEqual(self.results(self.source("v2", version="1.1.0", note="v2"), reset)["default"].status, "deferred")
        self.assertTrue(folder.is_dir())

    def test_a_linked_skill_is_kept_in_dev_mode_instead_of_failing_the_profile(self):
        self.apply(self.source("v1"), DEV)
        checkout = self.tmp / "checkout"
        os.rename(str(self.live(CODING)), str(checkout))
        os.symlink(str(checkout), str(self.live(CODING)))
        v2 = self.source("v2", version="1.1.0", note="v2")
        self.assertEqual(self.results(v2, DEV)["default"].status, "applied")
        self.assertTrue(self.live(CODING).is_symlink())
        self.assertEqual(self.snapshot(FEEDBACK), self.expected(v2, FEEDBACK))

    def test_python_caches_do_not_count_as_a_modification(self):
        self.apply(self.source("v1"), DEV)
        cache = self.live(CODING) / "scripts/__pycache__"
        cache.mkdir()
        (cache / "helper.cpython-312.pyc").write_bytes(b"\0cache")
        v2 = self.source("v2", version="1.1.0", note="v2")
        self.assertEqual(self.results(v2, DEV)["default"].status, "applied")
        self.assertEqual(self.snapshot(CODING), self.expected(v2, CODING))

    def test_the_content_digest_matches_the_apps_vector(self):
        self.assertEqual(devmode.files_digest([File(p, c) for p, c in VECTOR_FILES]), VECTOR)
        folder = self.tmp / "vector"
        for path, content in VECTOR_FILES:
            (folder / path).parent.mkdir(parents=True, exist_ok=True)
            (folder / path).write_text(content, encoding="utf-8")
            os.chmod(str(folder / path), 0o755 if path.startswith("scripts/") else 0o644)
        os.chmod(str(folder / "references"), 0o700)  # folder modes do not count
        (folder / "__pycache__").mkdir()
        (folder / "__pycache__/x.pyc").write_bytes(b"x")
        self.assertEqual(devmode.content_digest(str(folder)), VECTOR)
        os.chmod(str(folder / "SKILL.md"), 0o755)
        self.assertNotEqual(devmode.content_digest(str(folder)), VECTOR)


class Staged(DevCase):
    def start(self, profiles):
        _, comps = self.release("v1")
        code, out = self.update("apply", "--staged", str(self.stage(11, comps, profiles=profiles)))
        self.assertEqual((code, out["state"]), (0, "pending_confirm"), out["detail"])
        code, out = self.update("apply", "--version", "11")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])

    def update_to_v2(self, profiles):
        v2, comps = self.release("v2", version="1.1.0", note="v2")
        self.update("apply", "--staged", str(self.stage(12, comps, profiles=profiles)))
        code, out = self.update("apply", "--version", "12")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        return v2, comps, out

    def saved(self):
        return {p["name"]: p for p in json.loads((self.state / "profiles.json").read_bytes())["profiles"]}

    def test_kept_skills_are_reported_modified_and_the_run_stays_current(self):
        self.start(DEV_DOC)
        edited = self.edit(FEEDBACK)
        v2, comps, out = self.update_to_v2(DEV_DOC)
        self.assertEqual(out["profiles"]["default"]["modified"], [FEEDBACK])
        self.assertNotIn("modified", out["profiles"]["coder_2"], "dev mode off: no key, as before")
        self.assertEqual((self.live(FEEDBACK) / "SKILL.md").read_text(), edited)
        self.assertEqual(self.snapshot(CODING), self.expected(v2, CODING))
        self.assertEqual(out["profiles"]["default"]["advertised"][FEEDBACK], "1.0.0")
        record = apply.read_record(str(self.state), "default")
        self.assertNotEqual(record["variants"][FEEDBACK]["tree"], stage.tree_digest(str(self.live(FEEDBACK))),
                            "the bot's edit is never bound as the updater's own tree")
        self.assertTrue(self.saved()["default"]["dev_mode"])

        # Reset to bundled: the same signed bundle again, with one skill reset; the reset is not persisted.
        folder = self.override(FEEDBACK)
        reset = {"schema": DEV_DOC["schema"], "profiles": [dict(DEV_DOC["profiles"][0], reset=[FEEDBACK])]}
        code, out = self.update("apply", "--staged", str(self.stage(12, comps, profiles=reset)))
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assertEqual(self.snapshot(FEEDBACK), self.expected(v2, FEEDBACK))
        self.assertEqual(out["profiles"]["default"]["modified"], [])
        self.assertFalse(folder.exists())
        self.assertNotIn("reset", self.saved()["default"])
        code, out = self.update("check")
        self.assertEqual(out["profiles"]["default"]["modified"], [])

    def test_a_box_installed_before_dev_mode_updates_its_unmodified_skills(self):
        """The updater's bound trees prove which skills are still its own."""
        self.start(PROFILES_DOC)
        edited = self.edit(FEEDBACK)
        v2, _, out = self.update_to_v2(DEV_DOC)
        self.assertEqual(out["profiles"]["default"]["modified"], [FEEDBACK])
        self.assertEqual((self.live(FEEDBACK) / "SKILL.md").read_text(), edited)
        for name in (CODING, MANAGER, MESSAGES):
            self.assertEqual(self.snapshot(name), self.expected(v2, name), name)

    def test_dev_mode_off_in_profiles_json_overwrites_as_before(self):
        """REGRESSION through the CLI: no dev_mode key, the edit is replaced and nothing is reported or written."""
        self.start(PROFILES_DOC)
        self.edit(FEEDBACK)
        v2, _, out = self.update_to_v2(PROFILES_DOC)
        self.assertEqual(self.snapshot(FEEDBACK), self.expected(v2, FEEDBACK))
        self.assertNotIn("modified", out["profiles"]["default"])
        self.assertNotIn("dev_mode", self.saved()["default"])
        self.assertFalse((self.hermes / "swarmhub/dev-baseline").exists())

    def test_turning_dev_mode_off_lets_the_next_request_overwrite(self):
        self.start(DEV_DOC)
        self.edit(FEEDBACK)
        v2, comps, out = self.update_to_v2(DEV_DOC)
        self.assertEqual(out["profiles"]["default"]["modified"], [FEEDBACK])
        off = {"schema": DEV_DOC["schema"], "profiles": [PROFILES_DOC["profiles"][0]]}
        code, out = self.update("apply", "--staged", str(self.stage(12, comps, profiles=off)))
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assertEqual(self.snapshot(FEEDBACK), self.expected(v2, FEEDBACK))
        self.assertNotIn("dev_mode", self.saved()["default"])

    def test_a_persisted_reset_is_never_applied_again(self):
        self.start(DEV_DOC)
        doc = json.loads((self.state / "profiles.json").read_bytes())
        doc["profiles"][0]["reset"] = [FEEDBACK]  # hand-edited: only a request may reset
        (self.state / "profiles.json").write_text(json.dumps(doc))
        edited = self.edit(FEEDBACK)
        self.update_to_v2(None)
        self.assertEqual((self.live(FEEDBACK) / "SKILL.md").read_text(), edited)

    def test_malformed_dev_mode_keys_are_refused_before_anything_applies(self):
        _, comps = self.release("v1")
        for row in ({"dev_mode": "yes"}, {"reset": "swarmhub-feedback"}, {"reset": ["../x"]}):
            doc = {"schema": DEV_DOC["schema"], "profiles": [dict(PROFILES_DOC["profiles"][0], **row)]}
            code, out = self.update("apply", "--staged", str(self.stage(11, comps, profiles=doc)))
            self.assertEqual(out["last"]["reason"], "schema_invalid", row)
            self.assertFalse(self.live(FEEDBACK).exists())


if __name__ == "__main__":
    unittest.main()
