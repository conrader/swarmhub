"""Shared fixtures for the P2a apply-engine tests (test_apply.py, test_apply_engine.py): a temp box with a Hermes
home, two profiles, a Hermes stand-in, a peer plugin as the app installs it, and small skill sources whose scripts
exercise every check. Not a test module itself (unittest discovery loads test*.py only)."""

import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources/Updater"))

from swarmhub_update import apply, idle, render, stage  # noqa: E402

HERMES = ROOT / "Tests/Fixtures/hermes_v0.21.7_server.py"
RESOURCES = ROOT / "Resources"
PROFILES = [stage.Profile("default", "claude,codex,hermes", None),
            stage.Profile("coder_2", "codex", ("swarmhub-coding", "swarmhub-messages"))]
CODING, MESSAGES, MANAGER = "swarmhub-coding", "swarmhub-messages", "swarmhub-manager"

SKILL_MD = """---
name: {name}
description: Test skill {name}. Installed by SwarmHub, v{{{{VERSION}}}}.
version: {version}
---

# {name}

Order {{{{CODING_ORDER}}}} in {{{{SKILL_DIR}}}} for {{{{BOT}}}}. {note}
"""
MANAGER_MD = """---
name: swarmhub-manager
description: Manager. Installed by SwarmHub, v{{{{VERSION}}}}.
version: {version}
---

{{{{MANAGER_TEXT}}}}
"""
TOOL_PY = '''#!/usr/bin/env python3
"""Coding tool with a self-test."""
import sys
import helper

if __name__ == "__main__" and sys.argv[1:] == ["--self-test"]:
    sys.exit(0 if helper.answer() == {answer} else 1)
'''
HELPER_PY = "def answer():\n    return 42\n"
RUN_SH = "#!/bin/sh\n# runner {note}\nif [ \"$1\" = x ]; then echo x; fi\n"
PEER_PY = "#!/usr/bin/env python3\n\"\"\"Peer plugin stand-in.\"\"\"\nVERSION = {plugin!r}\n"
STORE_PY = "\"\"\"Store module the plugin imports.\"\"\"\nSTATE = 1\n"


def write_source(folder, version="1.0.0", note="v1", answer=42, plugin="p1", tool=None, run_sh=None, files=None):
    """A `Resources/`-shaped source with four small skills. Keyword overrides break one script on purpose."""
    folder = Path(folder)
    if folder.exists():
        shutil.rmtree(folder)
    skills = folder / "Skills"
    for name in (CODING, MESSAGES, "swarmhub-feedback"):
        (skills / name).mkdir(parents=True)
        (skills / name / "SKILL.md").write_text(SKILL_MD.format(name=name, version=version, note=note))
    (skills / MANAGER).mkdir(parents=True)
    (skills / MANAGER / "SKILL.md").write_text(MANAGER_MD.format(version=version))
    scripts = skills / CODING / "scripts"
    scripts.mkdir()
    (scripts / "tool.py").write_text(tool if tool is not None else TOOL_PY.format(answer=answer))
    (scripts / "helper.py").write_text(HELPER_PY)
    (scripts / "run").write_text(run_sh if run_sh is not None else RUN_SH.format(note=note))
    peer = skills / MESSAGES / "scripts"
    peer.mkdir()
    (peer / "peer-runtime.py").write_text(PEER_PY.format(plugin=plugin))
    (peer / "swarm_store.py").write_text(STORE_PY)
    for path, text in (files or {}).items():
        (skills / path).parent.mkdir(parents=True, exist_ok=True)
        (skills / path).write_text(text)
    recipes = folder / "BotManager" / "recipes"
    recipes.mkdir(parents=True)
    for recipe in render.RECIPES:
        (recipes / (recipe + ".md")).write_text("Recipe %s for {{MANAGER}} ({{MANAGER_ENV}}).\n" % recipe)
    (folder / "BotManager" / "manager-hermes.md").write_text("You manage {{MANAGER}}. Keys in {{MANAGER_ENV}}.\n")
    return stage.load_source(str(folder))


def box_snapshot(root):
    """{path relative to root: (kind, mode, sha256 of content or link target)} for the whole tree."""
    entries = {}
    for directory, folders, names in os.walk(root):
        for name in folders + names:
            full = os.path.join(directory, name)
            info = os.lstat(full)
            if stat.S_ISREG(info.st_mode):
                value = hashlib.sha256(Path(full).read_bytes()).hexdigest()
            elif stat.S_ISLNK(info.st_mode):
                value = os.readlink(full)
            else:
                value = None
            entries[os.path.relpath(full, root)] = (stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), value)
    return entries


def changed(before, after):
    return sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))


class BoxCase(unittest.TestCase):
    """A temp box: `self.home` (HOME), `self.hermes` (~/.hermes), `self.state` (updater state dir)."""

    def setUp(self):
        os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
        self.tmp = Path(tempfile.mkdtemp(prefix="p2a-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "home"
        self.hermes = self.home / ".hermes"
        self.state = self.home / ".local/state/swarmhub-update"
        agent = self.hermes / "hermes-agent/gateway/platforms"
        agent.mkdir(parents=True)
        shutil.copyfile(HERMES, agent / "api_server.py")
        (self.hermes / "config.yaml").write_text("model: test\n")
        (self.hermes / ".env").write_text("API_SERVER_KEY=not-a-real-key\n")
        (self.hermes / "skills/other-category/keep").mkdir(parents=True)
        (self.hermes / "skills/other-category/keep/SKILL.md").write_text("---\nname: keep\n---\n")
        plugin = self.hermes / "profiles/coder_2/plugins/swarmhub-peer"
        plugin.mkdir(parents=True)
        (plugin / "__init__.py").write_text("import runpy\n")
        (self.hermes / "swarmhub").mkdir()
        self.sources = self.tmp / "sources"

    def source(self, tag, **kwargs):
        return write_source(self.sources / tag, **kwargs)

    def apply(self, source, profiles=PROFILES, max_wait=0, poll=0.02):
        skills, manager = source
        return apply.apply(str(self.hermes), str(self.state), skills, manager, profiles, max_wait=max_wait, poll=poll)

    def category(self, profile="default"):
        return Path(stage.category_dir(str(self.hermes), profile))

    def live(self, skill, profile="default"):
        return self.category(profile) / skill

    def previous(self, skill, profile="default"):
        return Path(stage.work_dir(str(self.category(profile)))) / "previous" / skill

    def expected(self, source, skill, profile=PROFILES[0]):
        skills, manager = source
        return stage.expected_snapshot(stage.render_profile(skills, manager, profile)[skill])

    def assert_live(self, source, profile=PROFILES[0]):
        skills, manager = source
        for name, files in stage.render_profile(skills, manager, profile).items():
            self.assertEqual(stage.snapshot(str(self.live(name, profile.name))), stage.expected_snapshot(files), name)

    def assert_no_transactions(self, profile="default"):
        work = Path(stage.work_dir(str(self.category(profile))))
        self.assertEqual([p.name for p in work.glob("txn-*")] if work.exists() else [], [])

    def assert_no_pycache(self):
        self.assertEqual([str(p) for p in self.tmp.rglob("__pycache__")], [])

    def start_sleeper(self, seconds=30):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(%d)" % seconds])
        self.addCleanup(lambda: (child.kill(), child.wait()))
        return child

    def code_job_slot(self, pid, slot=1):
        lock = self.hermes / ("swarmhub/slots/%d.lock" % slot)
        lock.mkdir(parents=True)
        if pid is not None:
            (lock / "pid").write_text("%d\n" % pid)
        return lock

    def swarm_job(self, pid, status="running", ident="job-1"):
        db = sqlite3.connect(str(self.hermes / "swarmhub/control.sqlite"))
        db.execute("CREATE TABLE IF NOT EXISTS actions(id TEXT PRIMARY KEY, status TEXT, pid INTEGER)")
        db.execute("INSERT OR REPLACE INTO actions VALUES(?,?,?)", (ident, status, pid))
        db.commit()
        db.close()

    def set_job_status(self, status, ident="job-1"):
        db = sqlite3.connect(str(self.hermes / "swarmhub/control.sqlite"))
        db.execute("UPDATE actions SET status=? WHERE id=?", (status, ident))
        db.commit()
        db.close()


__all__ = ["apply", "idle", "render", "stage", "ROOT", "HERMES", "RESOURCES", "PROFILES", "CODING", "MESSAGES",
           "MANAGER", "write_source", "box_snapshot", "changed", "BoxCase"]
