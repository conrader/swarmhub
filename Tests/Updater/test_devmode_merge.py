"""Skill dev mode across bots on one box: the staged script's profiles.json merge (`StagedInstall.profileMerge`, taken
verbatim from Sources/AgentApp/Updates/StagedInstall.swift) followed by the real `apply --staged`.

Bot A turns dev mode on in the app and edits a skill; no request for A has gone out since, so the box's saved row for
A has no `dev_mode`. A signed install for bot B must still carry A's toggle (the app's `dev_modes` map), so A keeps
its edit and the box remembers A's dev mode.

    python3 -m unittest discover -s Tests/Updater
"""

import copy
import json
from pathlib import Path
import sys
import textwrap
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import CODING, FEEDBACK, PROFILES, PROFILES_DOC, ROOT, CliCase, stage  # noqa: E402

SWIFT = ROOT / "Sources/AgentApp/Updates/StagedInstall.swift"
A, B = "default", "coder_2"  # PROFILES_DOC's two rows


def swift_merge():
    text = SWIFT.read_text()
    source = textwrap.dedent(text.split('static let profileMerge = #"""\n', 1)[1].split('\n    """#', 1)[0])
    namespace = {}
    exec(compile(source, str(SWIFT), "exec"), namespace)  # noqa: S102 - the app's own text, as the box runs it
    return text, namespace["merge_profiles"]


SWIFT_TEXT, merge_profiles = swift_merge()


def row(name):
    return copy.deepcopy(next(p for p in PROFILES_DOC["profiles"] if p["name"] == name))


class Merge(CliCase):
    def setUp(self):
        super().setUp()
        _, comps = self.release("v1")
        self.update("apply", "--staged", str(self.stage(11, comps, profiles=PROFILES_DOC)))
        code, out = self.update("apply", "--version", "11")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.edited = self.live(FEEDBACK, A) / "SKILL.md"
        self.edited.write_text(self.edited.read_text() + "Edited on the box by bot A.\n")

    def saved(self):
        return json.loads((self.state / "profiles.json").read_bytes())

    def request_for_b(self, dev_modes, version=12, tag="v2"):
        """What the box script does for a signed install for B alone: merge, then apply --staged and confirm."""
        doc = merge_profiles(self.saved(), [row(B)], dev_modes)
        v2, comps = self.release(tag, version="1.1.0", note=tag)
        self.update("apply", "--staged", str(self.stage(version, comps, profiles=doc)))
        code, out = self.update("apply", "--version", str(version))
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        return v2, out

    def test_the_command_runs_this_merge_with_the_apps_map(self):
        self.assertIn("\\(profileMerge)\n", SWIFT_TEXT)
        self.assertIn("doc = merge_profiles(doc, incoming, \\(modes))", SWIFT_TEXT)
        self.assertEqual(SWIFT_TEXT.count("for row in incoming:"), 1, "the merge lives in profileMerge only")

    def test_a_signed_install_for_b_keeps_dev_mode_and_the_edit_of_a(self):
        v2, out = self.request_for_b({A: True, B: False})
        rows = {p["name"]: p for p in self.saved()["profiles"]}
        self.assertIs(rows[A].get("dev_mode"), True, "A's dev mode is saved on the box")
        self.assertNotIn("dev_mode", rows[B])
        self.assertIn("Edited on the box by bot A.", self.edited.read_text())
        self.assertEqual(out["profiles"][A]["modified"], [FEEDBACK])
        b = next(p for p in PROFILES if p.name == B)
        self.assertEqual(stage.snapshot(str(self.live(CODING, B))), self.expected(v2, CODING, b), "B is updated")

        # The next request for B keeps it, and A's edit survives again.
        self.request_for_b({A: True, B: False}, version=13, tag="v3")
        self.assertIs({p["name"]: p for p in self.saved()["profiles"]}[A].get("dev_mode"), True)
        self.assertIn("Edited on the box by bot A.", self.edited.read_text())

    def test_without_the_map_a_request_for_b_overwrites_a(self):
        """The bug this guards against: the merge used to ignore other bots' toggles."""
        self.request_for_b({})
        self.assertNotIn("Edited on the box by bot A.", self.edited.read_text())

    def test_turning_a_off_clears_its_saved_dev_mode_and_unknown_rows_stay(self):
        self.request_for_b({A: True, B: False})
        doc = self.saved()
        doc["profiles"].append({"name": "elsewhere", "coding_order": doc["profiles"][0]["coding_order"],
                                "skills": [FEEDBACK], "dev_mode": True})
        merged = merge_profiles(doc, [row(B)], {A: False, B: False})
        rows = {p["name"]: p for p in merged["profiles"]}
        self.assertNotIn("dev_mode", rows[A])
        self.assertIs(rows["elsewhere"]["dev_mode"], True, "a profile the app does not know is left alone")

    def test_with_dev_mode_off_everywhere_the_merged_doc_is_as_before(self):
        before = self.saved()
        incoming = [row(B)]
        merged = merge_profiles(copy.deepcopy(before), copy.deepcopy(incoming), {A: False, B: False})
        rows = {r["name"]: r for r in before["profiles"]}
        for r in incoming:
            r["skills"] = sorted(set(rows[r["name"]]["skills"] or []) | set(r["skills"])) \
                if rows[r["name"]].get("skills") is not None else None
            rows[r["name"]] = r
        self.assertEqual(json.dumps(merged), json.dumps(dict(before, profiles=list(rows.values()))))


if __name__ == "__main__":
    unittest.main()
