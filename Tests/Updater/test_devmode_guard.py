"""Skill dev mode on the legacy (shell) install path: the app's guard script and command templates, taken verbatim from
Sources/AgentApp/BotManager/SkillDevMode.swift and run with sh/dash/bash against a temp HOME, as the manager's terminal
would run them. Swift is unavailable on Linux: AgentAppTests check how the app assembles them; this suite runs the bytes.

    python3 -m unittest discover -s Tests/Updater
"""

from collections import namedtuple
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import textwrap
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import ROOT, BoxCase  # noqa: E402
from swarmhub_update import devmode  # noqa: E402

SWIFT = ROOT / "Sources/AgentApp/BotManager/SkillDevMode.swift"
SKILL = "swarmhub-feedback"
File = namedtuple("File", "path content")
V1 = [File("SKILL.md", "---\nname: swarmhub-feedback\nversion: 1.0.0\n---\nv1\n"), File("scripts/report", "#!/bin/sh\necho 1\n")]
V2 = [File("SKILL.md", "---\nname: swarmhub-feedback\nversion: 1.1.0\n---\nv2\n"), File("scripts/report", "#!/bin/sh\necho 2\n")]


def swift_parts():
    text = SWIFT.read_text()
    script = textwrap.dedent(text.split('static let guardScript = #"""\n', 1)[1].split('\n    """#', 1)[0])

    def literal(name):
        raw = re.search(r'static let %s = "((?:[^"\\]|\\.)*)"' % name, text).group(1)
        return raw.replace('\\n', '\n').replace('\\"', '"')
    return script, {n: literal(n) for n in ("functionHead", "functionTail", "guardHead", "guardTail", "resetHead",
                                     "resetTail")}


SCRIPT, PARTS = swift_parts()
SHELLS = [s for s in ("sh", "dash", "bash") if shutil.which(s)]


def command(files, profile="default", dev=True, reset=False):
    """What `skillInstallCommands` sends for one skill: the function, then the guarded (or reset) heredoc writes."""
    root = "~/.hermes/skills" if profile == "default" else "~/.hermes/profiles/%s/skills" % profile
    folder = "%s/swarmhub/%s" % (root, SKILL)
    body = ["mkdir -p %s %s/scripts" % (folder, folder)]
    body += ["cat > %s/%s <<'SWARMHUB_EOF'\n%sSWARMHUB_EOF" % (folder, f.path, f.content) for f in files]
    body.append("chmod 755 %s/scripts/report" % folder)

    def fill(template):
        return template.replace("{profile}", profile).replace("{skill}", SKILL) \
            .replace("{bundled}", devmode.files_digest(files))
    lines = [PARTS["functionHead"] + "\n" + SCRIPT + "\n" + PARTS["functionTail"]] if dev or reset else []
    if reset:
        lines += [fill(PARTS["resetHead"])] + body + [fill(PARTS["resetTail"])]
    elif dev:
        lines += [fill(PARTS["guardHead"])] + body + [fill(PARTS["guardTail"])]
    else:
        lines += body
    return "\n".join(lines) + "\n"


class Guard(BoxCase):
    def run_install(self, files, shell="sh", **kwargs):
        cmd = command(files, **kwargs)
        self.assertNotIn("SWARMHUB_DEV_KEPT:", cmd, "only the output may carry a marker")
        result = subprocess.run([shell, "-c", cmd], env={"HOME": str(self.home), "PATH": os.environ["PATH"]},
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.stderr, "", result.stderr)
        return result.stdout

    def folder(self, profile="default"):
        home = self.hermes if profile == "default" else self.hermes / "profiles" / profile
        return home / "skills/swarmhub" / SKILL

    def text(self, profile="default"):
        return (self.folder(profile) / "SKILL.md").read_text()

    def baseline(self, profile="default"):
        return devmode.read_baseline(str(self.hermes), profile, SKILL)

    def test_unmodified_skills_update_and_modified_ones_are_kept(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                shutil.rmtree(str(self.hermes / "skills/swarmhub"), ignore_errors=True)
                shutil.rmtree(str(self.hermes / "swarmhub/dev-baseline"), ignore_errors=True)
                self.assertEqual(self.run_install(V1, shell), "")  # absent: written, baseline recorded
                self.assertEqual(self.baseline(), devmode.content_digest(str(self.folder())))
                self.assertEqual(self.baseline(), devmode.files_digest(V1), "the app's bundled digest is the live one")
                self.assertTrue(os.access(str(self.folder() / "scripts/report"), os.X_OK))
                self.assertEqual(self.run_install(V2, shell), "")  # still SwarmHub's copy: updated
                self.assertIn("v2", self.text())
                (self.folder() / "SKILL.md").write_text(self.text() + "bot edit\n")
                edited = self.text()
                out = self.run_install(V1, shell)
                self.assertEqual(out, "SWARMHUB_DEV_KEPT:default/%s\n" % SKILL)
                self.assertEqual(self.text(), edited)

    def test_dev_mode_off_overwrites_a_modified_skill(self):
        """REGRESSION: the commands without dev mode are today's, and they replace the bot's edit."""
        self.run_install(V1)
        (self.folder() / "SKILL.md").write_text("bot edit\n")
        self.assertNotIn("swarmhub_dev", command(V2, dev=False))
        self.assertEqual(self.run_install(V2, dev=False), "")
        self.assertIn("v2", self.text())

    def test_an_override_folder_keeps_the_skill(self):
        self.run_install(V1, profile="coder_2")
        (self.hermes / "swarmhub/dev-overrides/coder_2" / SKILL).mkdir(parents=True)
        self.assertEqual(self.run_install(V2, profile="coder_2"), "SWARMHUB_DEV_KEPT:coder_2/%s\n" % SKILL)
        self.assertIn("v1", self.text("coder_2"))

    def test_no_baseline_keeps_a_differing_skill_but_not_the_bundled_copy(self):
        self.run_install(V1, dev=False)  # installed before dev mode: no baseline
        self.assertEqual(self.run_install(V2), "SWARMHUB_DEV_KEPT:default/%s\n" % SKILL)
        self.assertIsNone(self.baseline())
        self.assertEqual(self.run_install(V1), "")  # identical to the bundled copy: written, baseline recorded
        self.assertEqual(self.baseline(), devmode.files_digest(V1))
        self.assertEqual(self.run_install(V2), "")

    def test_reset_to_bundled_overwrites_and_removes_the_override(self):
        self.run_install(V1)
        (self.folder() / "SKILL.md").write_text("bot edit\n")
        override = self.hermes / "swarmhub/dev-overrides/default" / SKILL
        (override / "sub").mkdir(parents=True)
        (override / "sub/notes.md").write_text("working copy\n")
        sibling = self.hermes / "swarmhub/dev-overrides/default/swarmhub-coding"
        sibling.mkdir()
        self.assertEqual(self.run_install(V2, reset=True), "")
        self.assertIn("v2", self.text())
        self.assertFalse(override.exists())
        self.assertTrue(sibling.is_dir())
        self.assertEqual(self.baseline(), devmode.content_digest(str(self.folder())))
        self.assertEqual(self.run_install(V1), "", "after a reset the skill is SwarmHub's again")

    def test_reset_restores_exactly_the_bundled_folder_and_records_its_digest(self):
        """Files the bot added are gone after a reset (kept aside, the last reset's only), and the baseline is the
        bundled digest, so the next install updates the skill instead of keeping it."""
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.run_install(V1, shell)
                (self.folder() / "SKILL.md").write_text("bot edit\n")
                (self.folder() / "notes").mkdir(exist_ok=True)
                (self.folder() / "notes/plan.md").write_text("added by the bot\n")
                (self.folder() / "scripts/extra").write_text("#!/bin/sh\n")
                self.assertEqual(self.run_install(V2, shell, reset=True), "")
                self.assertEqual(sorted(str(p.relative_to(self.folder())) for p in self.folder().rglob("*")),
                                 ["SKILL.md", "scripts", "scripts/report"])
                self.assertEqual(devmode.content_digest(str(self.folder())), devmode.files_digest(V2))
                self.assertEqual(self.baseline(), devmode.files_digest(V2))
                aside = self.hermes / "swarmhub/dev-reset/default" / SKILL
                self.assertEqual((aside / "notes/plan.md").read_text(), "added by the bot\n")
                self.assertEqual(self.run_install(V1, shell), "", "SwarmHub's copy again: the next install writes")
                self.assertIn("v1", self.text())

    def test_a_reset_that_cannot_clear_the_folder_writes_nothing(self):
        self.run_install(V1)
        (self.folder() / "SKILL.md").write_text("bot edit\n")
        blocker = self.hermes / "swarmhub/dev-reset/default"
        blocker.parent.mkdir(parents=True)
        os.symlink(str(self.tmp), str(blocker))  # a linked dev-reset folder: never written through
        (self.tmp / SKILL).mkdir()
        self.assertEqual(self.run_install(V2, reset=True), "SWARMHUB_DEV_FAILED:default/%s\n" % SKILL)
        self.assertEqual(self.text(), "bot edit\n")
        self.assertTrue((self.tmp / SKILL).is_dir())

    def test_reset_never_follows_a_linked_overrides_folder(self):
        self.run_install(V1)
        elsewhere = self.tmp / "elsewhere"
        (elsewhere / SKILL).mkdir(parents=True)
        (self.hermes / "swarmhub/dev-overrides").mkdir(parents=True)
        os.symlink(str(elsewhere), str(self.hermes / "swarmhub/dev-overrides/default"))
        self.run_install(V2, reset=True)
        self.assertTrue((elsewhere / SKILL).is_dir())

    def test_the_updater_honours_a_baseline_the_guard_recorded(self):
        """One rule on both paths: a box moved from the shell installer to the updater keeps its proof."""
        self.run_install(V1)
        self.assertFalse(devmode.modified(str(self.hermes), {}, "default", SKILL, str(self.folder())))
        (self.folder() / "SKILL.md").write_text("bot edit\n")
        self.assertTrue(devmode.modified(str(self.hermes), {}, "default", SKILL, str(self.folder())))

    def test_no_dev_mode_command_trips_hermes_hardline_guard(self):
        sys.path.insert(0, str(ROOT / "sim"))
        import test_skill_guard_phrases as guard
        for kwargs in ({}, {"reset": True}, {"profile": "coder_2"}):
            self.assertEqual(guard.matches(command(V1, **kwargs)), [], kwargs)

    def test_bad_names_and_a_missing_python_never_write(self):
        cmd = command(V1).replace("python3 -I -B -", "no-such-python3 -I -B -")
        result = subprocess.run(["sh", "-c", cmd], env={"HOME": str(self.home), "PATH": os.environ["PATH"]},
                                capture_output=True, text=True, timeout=60)
        self.assertIn("SWARMHUB_DEV_FAILED:default/%s" % SKILL, result.stdout)
        self.assertFalse(self.folder().exists())
        bad = subprocess.run([sys.executable, "-I", "-B", "-", "check", "../x", SKILL, "0" * 64], input=SCRIPT,
                             env={"HOME": str(self.home)}, capture_output=True, text=True, timeout=60)
        self.assertEqual(bad.returncode, 2)


if __name__ == "__main__":
    unittest.main()
