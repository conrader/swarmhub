"""P2a acceptance: the updater apply engine (Resources/Updater/swarmhub_update/{apply,stage,idle}.py).

On temp profile trees (apply_fixtures.BoxCase): a failed check leaves `current` byte-identical; a running job defers
the swap, which then applies after the job ends; open file handles in `current` survive the swap; a peer-plugin
change sets `reload_pending` and never restarts anything; writes stay under the profiles' `skills/swarmhub/` and the
state dir; the Hermes stand-in is unchanged; no `__pycache__` is left anywhere. Engine internals (recovery, fallback
rename, revert, lock) are in test_apply_engine.py.

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Updater
"""

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from apply_fixtures import (CODING, HERMES, MESSAGES, PROFILES, RESOURCES, ROOT, BoxCase, apply,  # noqa: E402
                            box_snapshot, changed, stage)

RENDERS = ROOT / "Tests/Fixtures/release-bundles/renders"


class FirstInstall(BoxCase):
    def test_installs_rendered_skills_with_app_modes(self):
        v1 = self.source("v1")
        results = self.apply(v1)
        self.assertEqual([r.status for r in results], ["applied", "applied"], results)
        self.assert_live(v1)
        self.assert_live(v1, PROFILES[1])
        self.assertFalse(self.live("swarmhub-manager", "coder_2").exists())  # not in coder_2's skill list
        self.assertEqual(os.stat(self.live(CODING) / "scripts/run").st_mode & 0o777, 0o755)
        self.assertEqual(os.stat(self.live(CODING) / "SKILL.md").st_mode & 0o777, 0o644)
        record = apply.read_record(str(self.state), "default")
        self.assertEqual(record["skills"], {s.name: "1.0.0" for s in v1[0]})
        self.assertTrue(self.previous(CODING + ".absent").exists())
        self.assert_no_transactions()
        self.assert_no_pycache()

    def test_real_resources_render_as_the_goldens(self):
        skills, manager = stage.load_source(str(RESOURCES))
        profiles = [stage.Profile("default", "claude,codex,hermes", None), stage.Profile("coder_2", "codex", None),
                    stage.Profile("grok-jarvis", "hermes", None)]
        (self.hermes / "profiles/grok-jarvis").mkdir(parents=True)
        caches = sorted(str(p) for p in (RESOURCES / "Skills").rglob("__pycache__"))
        results = apply.apply(str(self.hermes), str(self.state), skills, manager, profiles, max_wait=0)
        self.assertEqual([r.status for r in results], ["applied"] * 3, results)
        for profile in profiles:
            for skill in skills:
                text = (self.live(skill.name, profile.name) / "SKILL.md").read_bytes()
                slug = (stage.render.variant(skill, profile.coding_order) or "any-order").replace(",", "-")
                golden = RENDERS / skill.name / profile.name / slug / "SKILL.md"
                self.assertEqual(text, golden.read_bytes(), str(golden))
        self.assertEqual(sorted(str(p) for p in (RESOURCES / "Skills").rglob("__pycache__")), caches)
        self.assertEqual(list(RENDERS.rglob("__pycache__")), [])
        self.assert_no_pycache()


class FailedCheck(BoxCase):
    """A failed check leaves current (and previous) byte-identical and no staging behind."""

    BROKEN = {
        "python syntax": (dict(tool="#!/usr/bin/env python3\ndef broken(:\n"), "tool.py does not compile"),
        "python module syntax": (dict(files={CODING + "/scripts/extra.py": "x = = 1\n"}), "extra.py does not compile"),
        "shell syntax": (dict(run_sh="#!/bin/sh\nif [ x = x ]; then\n"), "run fails sh -n"),
        "self-test fails": (dict(answer=41), "tool.py --self-test exited 1"),
        "self-test hangs": (dict(tool="#!/usr/bin/env python3\nimport time\n# --self-test\ntime.sleep(30)\n"),
                            "--self-test timed out"),
        "self-test writes into the staged tree": (dict(
            tool="#!/usr/bin/env python3\n# --self-test\nopen('scripts/new.txt', 'w').write('x')\n"),
            "a check changed the staged tree"),
        "self-test without interpreter line": (dict(files={CODING + "/scripts/plain": "echo --self-test\n"}),
                                               "has no interpreter line"),
    }

    def check_broken(self, label, kwargs, reason):
        self.assertEqual({r.status for r in self.apply(self.source("v1"))}, {"applied"})
        self.assertEqual({r.status for r in self.apply(self.source("v2", version="1.1.0", note="v2"))}, {"applied"})
        before = box_snapshot(self.home)
        with mock.patch.object(stage, "SELF_TEST_TIMEOUT", 2):
            results = self.apply(self.source("bad", version="1.2.0", note="bad", **kwargs))
        for result in results:
            self.assertEqual(result.status, "failed", label)
            self.assertIn("check failed, current untouched", result.detail)
            self.assertIn(reason, result.detail)
        state = os.path.relpath(self.state, self.home)
        self.assertEqual([p for p in changed(before, box_snapshot(self.home)) if not p.startswith(state)], [], label)
        self.assertEqual(apply.read_record(str(self.state), "default")["skills"][CODING], "1.1.0")
        self.assert_no_transactions()
        self.assert_no_pycache()

    def test_frontmatter_must_parse_and_match(self):
        self.apply(self.source("v1"))
        before = box_snapshot(self.category())
        skills, manager = self.source("v2", version="1.1.0")
        bad = skills[0]._replace(template=skills[0].template.replace("name: " + skills[0].name, "name: other"))
        results = apply.apply(str(self.hermes), str(self.state), [bad] + skills[1:], manager, PROFILES[:1], max_wait=0)
        self.assertEqual(results[0].status, "failed")
        self.assertIn("frontmatter", results[0].detail)
        self.assertEqual(box_snapshot(self.category()), before)

    def test_checks_never_leave_bytecode_even_without_the_environment_flag(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("PYTHONDONTWRITEBYTECODE", None)
            self.assertEqual({r.status for r in self.apply(self.source("v1"))}, {"applied"})
        self.assert_no_pycache()


for _label, (_kwargs, _reason) in FailedCheck.BROKEN.items():
    setattr(FailedCheck, "test_" + _label.replace(" ", "_").replace("-", "_"),
            lambda self, label=_label, kwargs=_kwargs, reason=_reason: self.check_broken(label, kwargs, reason))


class IdleWait(BoxCase):
    def test_running_code_job_defers_then_applies_after_it_ends(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2")
        self.apply(v1)
        job = self.start_sleeper()
        self.code_job_slot(job.pid)
        current = box_snapshot(self.category())
        results = self.apply(v2, max_wait=0.3)
        self.assertEqual({r.status for r in results}, {"deferred"})
        self.assertIn("code-job pid %d" % job.pid, results[0].detail)
        self.assertEqual(box_snapshot(self.category()), current)
        self.assert_no_transactions()

        def finish():
            time.sleep(0.4)
            job.kill()
            job.wait()
        ender = threading.Thread(target=finish)
        started = time.monotonic()
        ender.start()
        results = self.apply(v2, max_wait=20)
        ender.join()
        self.assertEqual({r.status for r in results}, {"applied"}, results)
        self.assertGreaterEqual(time.monotonic() - started, 0.4)
        self.assert_live(v2)

    def test_running_swarm_job_defers_then_applies_after_it_ends(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2")
        self.apply(v1)
        job = self.start_sleeper()
        self.swarm_job(job.pid)
        db = self.hermes / "swarmhub/control.sqlite"
        db_bytes = db.read_bytes()
        results = self.apply(v2)
        self.assertEqual({r.status for r in results}, {"deferred"})
        self.assertIn("swarm job job-1", results[0].detail)
        self.assertEqual(db.read_bytes(), db_bytes)  # read only
        self.assertEqual([p.name for p in db.parent.iterdir() if p.name.startswith("control")], ["control.sqlite"])
        self.assert_live(v1)
        self.set_job_status("done")
        self.assertEqual({r.status for r in self.apply(v2)}, {"applied"})
        self.assert_live(v2)


class OpenHandles(BoxCase):
    def test_open_files_in_current_survive_the_swap(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2")
        self.apply(v1)
        old_md = (self.live(CODING) / "SKILL.md").read_bytes()
        old_run = (self.live(CODING) / "scripts/run").read_bytes()
        handle = open(self.live(CODING) / "SKILL.md", "rb")
        self.addCleanup(handle.close)
        head = handle.read(10)
        reader = subprocess.Popen(
            [sys.executable, "-c", "import sys, time\nf = open(sys.argv[1], 'rb')\nsys.stdout.write('ready\\n')\n"
             "sys.stdout.flush()\nsys.stdin.readline()\nsys.stdout.buffer.write(f.read())\n",
             str(self.live(CODING) / "scripts/run")], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(lambda: reader.poll() is None and reader.kill())
        self.assertEqual(reader.stdout.readline(), b"ready\n")
        self.assertEqual({r.status for r in self.apply(v2)}, {"applied"})
        self.assertNotEqual((self.live(CODING) / "SKILL.md").read_bytes(), old_md)
        self.assertEqual(head + handle.read(), old_md)
        self.assertGreaterEqual(os.fstat(handle.fileno()).st_nlink, 1)  # kept as previous, not unlinked
        output, _ = reader.communicate(b"go\n", timeout=10)
        self.assertEqual(output, old_run)
        self.assertEqual((self.previous(CODING) / "SKILL.md").read_bytes(), old_md)


class PeerPlugin(BoxCase):
    def test_plugin_change_sets_reload_pending_and_restarts_nothing(self):
        self.apply(self.source("v1"))
        apply.clear_reload_pending(str(self.state), "coder_2")
        apply.clear_reload_pending(str(self.state), "default")
        gateway = self.start_sleeper(60)
        (self.hermes / "gateway.pid").write_text("%d\n" % gateway.pid)

        launched, signals = [], []
        real_popen_init, real_kill = subprocess.Popen.__init__, os.kill

        def popen_init(popen, args, *rest, **kwargs):
            launched.append(list(args))
            return real_popen_init(popen, args, *rest, **kwargs)

        def kill(pid, sig):
            signals.append((pid, sig))
            return real_kill(pid, sig)

        with mock.patch.object(subprocess.Popen, "__init__", popen_init), mock.patch.object(os, "kill", kill), \
                mock.patch.object(os, "killpg", side_effect=AssertionError("killpg")), \
                mock.patch.object(os, "system", side_effect=AssertionError("system")):
            same_plugin = self.apply(self.source("v2", version="1.1.0", note="v2"))
            self.assertEqual({r.status for r in same_plugin}, {"applied"})
            self.assertEqual({r.reload_pending for r in same_plugin}, {False})
            new_plugin = self.apply(self.source("v3", version="1.2.0", note="v3", plugin="p2"))
        self.assertEqual({r.status for r in new_plugin}, {"applied"})
        self.assertEqual({r.reload_pending for r in new_plugin}, {True})
        self.assertTrue(apply.read_record(str(self.state), "coder_2")["reload_pending"])
        self.assertIsNone(gateway.poll())
        self.assertEqual({sig for _, sig in signals}, set())  # no busy job: not even signal 0 was needed
        work = [str(Path(stage.work_dir(str(self.category(p.name))))) for p in PROFILES]
        for argv in launched:  # only checks of staged scripts: `<shell> -n <staged>` or `<staged> --self-test`
            staged = argv[2] if argv[1:2] == ["-n"] else argv[0]
            self.assertTrue(any(staged.startswith(w + os.sep) for w in work), argv)
            self.assertTrue(argv[1:2] == ["-n"] or argv[1:] == ["--self-test"], argv)
        self.assertTrue(launched)
        self.assertEqual((self.hermes / "profiles/coder_2/plugins/swarmhub-peer/__init__.py").read_text(),
                         "import runpy\n")


class Confinement(BoxCase):
    def test_writes_stay_under_skills_swarmhub_and_state_and_hermes_is_unchanged(self):
        before = box_snapshot(self.home)
        hermes_file = self.hermes / "hermes-agent/gateway/platforms/api_server.py"
        statuses = [r.status for r in self.apply(self.source("v1"))]
        statuses += [r.status for r in self.apply(self.source("v2", version="1.1.0", note="v2", plugin="p2"))]
        statuses += [r.status for r in self.apply(self.source("bad", version="1.2.0", answer=0))]
        job = self.start_sleeper()
        self.code_job_slot(job.pid, slot=2)
        statuses += [r.status for r in self.apply(self.source("v3", version="1.3.0"))]
        job.kill()
        job.wait()
        statuses.append(apply.revert(str(self.hermes), str(self.state), "default", max_wait=0).status)
        self.assertEqual(statuses, ["applied"] * 4 + ["failed"] * 2 + ["deferred"] * 2 + ["reverted"])
        roots = [os.path.relpath(self.category(p.name), self.home) for p in PROFILES]
        roots += [os.path.relpath(self.state, self.home), ".hermes/swarmhub/slots"]  # last: this test's job stand-in

        def allowed(path):  # inside an allowed root, or a folder created on the way to one
            return any(path == r or path.startswith(r + "/") or r.startswith(path + "/") for r in roots)
        after = box_snapshot(self.home)
        self.assertEqual([p for p in changed(before, after) if not allowed(p)], [])
        for path in changed(before, after):
            if any(r.startswith(path + "/") for r in roots):
                self.assertNotIn(path, before)  # an ancestor only ever appears, never changes
        self.assertEqual(hashlib.sha256(hermes_file.read_bytes()).digest(), hashlib.sha256(HERMES.read_bytes()).digest())
        self.assertEqual(before[".hermes/.env"], after[".hermes/.env"])
        self.assertEqual(before[".hermes/config.yaml"], after[".hermes/config.yaml"])
        self.assert_no_pycache()


if __name__ == "__main__":
    unittest.main()
