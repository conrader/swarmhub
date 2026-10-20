"""macsmoke2/3 regressions for sim/mac-codex-tmp-smoke.sh (no Codex, no provider, no network).

Covers the macsmoke1 review: cleanup with a space in $TMPDIR, a timed-out run whose probe files exist, an
unexpected write on a first run that also timed out, and the non-fallback code-job run in the default command.
macsmoke3 adds the fresh-report/empty-stdout exit-65 reproduction, deterministic completion, fail-closed report
checks, launcher timeout/nonzero checks, and a symlinked TMPDIR. Fixtures work on Linux and macOS.
mactest1/2: the fixture stops python3 bytecode in HOME; only exact OS-made HOME/Library shapes pass, Darwin only.
"""
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "sim/mac-codex-tmp-smoke.sh"
# Separate HOME and TMPDIR siblings outside system /tmp. Works on a Mac checkout in /tmp/qm6 too;
# /dev/shm is Linux-only, and a checkout outside /tmp also works in a workspace-write sandbox.
FIXTURE_BASE = ROOT if Path('/tmp').resolve() not in ROOT.parents else Path.home()


DARWIN = sys.platform == "darwin"
# mactest2: Xcode's python3 sets sys.pycache_prefix to ~/Library/Caches/com.apple.python, so in a fresh fake HOME the
# smoke's helper `python3 -c` calls create ~/Library on their first import. run_smoke removes that cause
# (PYTHONDONTWRITEBYTECODE=1, and any prefix pointed into the fixture), so HOME must stay empty. If macOS still makes
# a Library (CFPreferences), os_library_problems accepts it on Darwin only, as an allowlist of exact OS shapes:
# stdlib-style bytecode under Caches/com.apple.python/<real source dir>/ and com.apple.*.plist directly in
# Preferences. Everything else fails: other names, empty dirs, symlinks, specials, and any walk/stat/read error.
PYC_PREFIX = ("Caches", "com.apple.python")
PYC_NAME = re.compile(r"(.+)\.cpython-\d+(?:\.opt-[12])?\.pyc")
PLIST_NAME = re.compile(r"com\.apple\.[A-Za-z0-9_.-]+\.plist")


def under(path, fixtures):
    paths = (str(path), os.path.realpath(path))
    return any(p == f or p.startswith(f.rstrip("/") + "/") for p in paths for f in fixtures)


def os_library_file(rel, data, fixtures):
    """Why the regular file <HOME>/Library/<rel> is not an OS-owned shape; None if it is."""
    parts = rel.parts
    if len(parts) == 2 and parts[0] == "Preferences" and PLIST_NAME.fullmatch(parts[1]):
        return None if data.startswith((b"bplist00", b"<?xml", b"<plist")) else "not a property list"
    match = PYC_NAME.fullmatch(parts[-1])
    if not (len(parts) > 3 and parts[:2] == PYC_PREFIX and match):
        return "not an OS-owned file"
    source = Path("/", *parts[2:-1], match[1] + ".py")
    if under(source.parent, fixtures):
        return "bytecode of a fixture source"
    try:
        if not stat.S_ISREG(os.stat(source).st_mode):
            return "bytecode without a real source"
    except OSError:
        return "bytecode without a real source"
    return None if len(data) >= 16 and data[2:4] == b"\r\n" else "not CPython bytecode"


def os_library_problems(library, markers, fixtures=()):
    """Reasons <HOME>/Library is not purely OS-created; [] if it is. Fails closed, never follows symlinks."""
    try:
        if not stat.S_ISDIR(library.lstat().st_mode):
            return ["Library: not a plain directory"]
    except OSError as error:
        return [f"Library: unreadable ({error.strerror})"]
    fixtures = {f for p in (*fixtures, ROOT) for f in (str(p), os.path.realpath(p))}
    label = lambda path: str(Path(path).relative_to(library)) if Path(path) != library else "Library"
    problems = []
    def unreadable(error):
        problems.append(f"{label(error.filename or library)}: unreadable ({error.strerror})")
    for dirpath, dirnames, filenames in os.walk(library, onerror=unreadable):
        if not dirnames and not filenames:
            problems.append(f"{label(dirpath)}: empty directory")
        for name in dirnames + filenames:
            path = Path(dirpath, name)
            rel = path.relative_to(library)
            try:
                mode = path.lstat().st_mode
                if stat.S_ISDIR(mode):
                    continue
                if not stat.S_ISREG(mode):
                    problems.append(f"{rel}: not a regular file or directory")
                    continue
                data = path.read_bytes()
            except OSError as error:
                problems.append(f"{rel}: unreadable ({error.strerror})")
                continue
            reason = os_library_file(rel, data, fixtures)
            if reason:
                problems.append(f"{rel}: {reason}")
            elif any(marker in data for marker in markers):
                problems.append(f"{rel}: mentions a smoke fixture path")
    return problems


def temp_entries():
    return {p.name for p in Path("/tmp").iterdir() if re.match(r"(code-job|macsmoke1)", p.name)}


@unittest.skipIf(os.geteuid() == 0, "the stub denies writes with permission bits, which root ignores")
@unittest.skipUnless(shutil.which("python3"), "needs python3")
class SmokeStubTests(unittest.TestCase):
    def setUp(self):
        self.shm = Path(tempfile.mkdtemp(prefix="msk2.", dir=FIXTURE_BASE))
        self.addCleanup(shutil.rmtree, self.shm, True)
        self.home = Path(tempfile.mkdtemp(prefix="msk2-home.", dir=FIXTURE_BASE))
        self.addCleanup(shutil.rmtree, self.home, True)
        self.before = temp_entries()

    def run_smoke(self, tmpdir, *args, log="-", script=SCRIPT, path=None):
        tmpdir.mkdir(parents=True, exist_ok=True)
        env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "SMOKE_TEED")}
        env.update(TMPDIR=str(tmpdir), HOME=str(self.home), SMOKE_LOG=str(log),
                   PYTHONDONTWRITEBYTECODE="1", PYTHONPYCACHEPREFIX=str(self.shm / "pycache"))
        if path:
            env["PATH"] = f"{path}{os.pathsep}{env.get('PATH', os.defpath)}"
        proc = subprocess.run(["sh", str(script), "--timeout", "3", *args], cwd=self.shm, env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
        out = proc.stdout + proc.stderr
        last = [line for line in out.splitlines() if line.startswith("smoke: ")]
        self.assertTrue(last, out[-3000:])
        self.assertEqual(list(tmpdir.iterdir()), [], "disposable dirs left in $TMPDIR")
        left = sorted(p.name for p in self.home.iterdir())
        if DARWIN and "Library" in left:
            paths = {str(p) for p in (self.shm, self.home, tmpdir)}
            paths |= {os.path.realpath(p) for p in paths}
            markers = [os.fsencode(p) for p in paths] + [b"macsmoke", b"code-job"]
            problems = os_library_problems(self.home / "Library", markers, (self.shm, self.home, tmpdir))
            self.assertEqual(problems, [], "smoke files in HOME/Library")
            left.remove("Library")
        self.assertEqual(left, [], "outside dir left in HOME")
        self.assertEqual(temp_entries() - self.before, set(), "disposable dirs left in /tmp")
        self.assertIn("cleanup: all disposable directories removed", out)
        self.assertNotIn("REFUSED", out)
        return proc.returncode, last[-1], out

    def test_space_in_tmpdir_cleans_exactly_and_default_run_covers_cj_outside(self):
        decoy = self.shm / "td"  # what an unquoted split of "<shm>/td x/..." would hit
        decoy.mkdir()
        (decoy / "canary").write_text("keep\n")
        rc, last, out = self.run_smoke(self.shm / "td x", "--stub")
        self.assertEqual((decoy / "canary").read_text(), "keep\n")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=PASS "), last)
        self.assertIn("cj-outside", last.split(" enforced=")[1].split(" ")[0])
        self.assertIn("expect fallback=no", out)
        self.assertNotIn("skipped=", last)

    def test_timeout_with_probe_files_present_is_never_pass(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "timeout")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=INCONCLUSIVE reason=first-run:timeout "), last)
        self.assertIn("positive control: written; completion marker: written; exit: 124 -> inconclusive (timeout)", out)

    def test_probe_without_completion_marker_is_inconclusive(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "incomplete")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=INCONCLUSIVE "), last)
        for run in ("on", "off", "slash", "tmpdir", "cj-home", "cj-sibling", "cj-outside"):
            self.assertIn(f"{run}:probe-incomplete", last)
        self.assertNotIn("enforced=cj", last)

    def test_unexpected_write_on_timed_out_first_run_fails_through_the_log_tee(self):
        log = self.shm / "smoke.log"
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "leaky-timeout", log=log)
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=FAIL reason=first-run:timeout "), last)
        self.assertIn("unexpected=on:tmp,on:tmpdir", last)
        self.assertIn(last, log.read_text())

    def test_leaky_full_run_fails(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "leaky")
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=FAIL "), last)
        for loc in ("on:tmp", "on:tmpdir", "cj-home:snapshot", "cj-sibling:snapshot"):
            self.assertIn(loc, last)

    def test_stderr_only_probe_reproduces_exit_65_without_shim_status(self):
        # A real fresh report and completed probe can still hit 65: code-job also requires stdout.
        # Revert only the harness status line, leaving all production launcher checks intact.
        with tempfile.NamedTemporaryFile(mode='w', prefix='macsmoke3-', suffix='.sh',
                                         dir=SCRIPT.parent) as old:
            status = "printf 'smoke shim: codex exited %s\\n' \"$rc\"\n"
            source = SCRIPT.read_text()
            self.assertEqual(source.count(status), 1)
            old.write(source.replace(status, ''))
            old.flush()
            rc, last, out = self.run_smoke(self.shm / 'td', '--stub', 'stderr-only', script=old.name)
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=INCONCLUSIVE '), last)
        for run in ('cj-home', 'cj-sibling', 'cj-outside'):
            self.assertIn(f'{run}:code-job-exit-65', last)
        self.assertEqual(out.count('  | report-before=missing-or-empty\n'), 3)
        self.assertEqual(out.count('  | report-valid=true\n'), 3)
        self.assertEqual(out.count('  | codex-stdout-bytes=0\n'), 3)
        self.assertEqual(out.count('completion marker: written; exit: 65'), 3)

    def test_stderr_only_completed_probe_passes_without_model_report_rewrite(self):
        # Also exercise physical-vs-given TMPDIR spellings; the report is written only by the probe.
        real = self.shm / 'td real'
        real.mkdir()
        alias = self.shm / 'td alias'
        alias.symlink_to(real, target_is_directory=True)
        rc, last, out = self.run_smoke(alias, '--stub', 'stderr-only')
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=PASS '), last)
        for run in ('cj-home', 'cj-sibling', 'cj-outside'):
            self.assertIn(run, last.split(' enforced=')[1].split(' ')[0])
        self.assertEqual(out.count('  | codex-stdout-bytes=0\n'), 3)
        self.assertEqual(out.count('  | report-before=missing-or-empty\n'), 3)
        self.assertEqual(out.count('  | report-valid=true\n'), 3)

    def test_mac_fallback_record_is_reproduced_and_located(self):
        # mac-smoke3-533593b: stdout DONE (5 bytes), the probe logs its report WROTE, symlinked TMPDIR, yet the
        # launcher records report-exists=true and report-sha256=missing-or-empty. The same layout with the probe's
        # 44-byte report intact passes; an emptied one is named at every step and never passes.
        real = self.shm / 'td real'
        real.mkdir()
        alias = self.shm / 'td alias'
        alias.symlink_to(real, target_is_directory=True)
        rc, last, out = self.run_smoke(alias, '--stub')
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=PASS '), last)
        self.assertEqual(out.count('  | codex-stdout-bytes=5\n'), 3)
        self.assertEqual(out.count('  | report-state=ok\n'), 3)
        self.assertEqual(out.count('  report timeline: cli-exit python:bytes-44 sh:nonempty; verify ok (44 bytes); '
                                   'finish nonempty; host now python:bytes-44 sh:nonempty\n'), 3)
        rc, last, out = self.run_smoke(alias, '--stub', 'emptied-report')
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=REPORT_FAILURE '), last)
        self.assertIn(' unexpected=none ', last)
        for run in ('cj-home', 'cj-sibling', 'cj-outside'):
            label = 'report' if run == 'cj-outside' else 'fallback-report'
            self.assertIn(f'{run}:{label}-empty', last)
        self.assertEqual(len(re.findall(r'\| report /[^\n]+/REPORT\.txt: WROTE\n', out)), 6)  # transcript + probe log
        for line in ('  | codex-stdout-bytes=5\n', '  | report-exists=true\n', '  | report-sha256=missing-or-empty\n',
                     '  | report-valid=false\n', '  | report-final=empty\n',
                     '  report timeline: cli-exit python:empty sh:empty; verify empty (0 bytes); finish empty; '
                     'host now python:empty sh:empty\n'):
            self.assertEqual(out.count(line), 3, line)

    def test_missing_and_unchanged_reports_still_exit_65(self):
        for mode in ('missing-report', 'unchanged-report'):
            with self.subTest(mode=mode):
                rc, last, out = self.run_smoke(self.shm / 'td', '--stub', mode)
                self.assertEqual(rc, 1, out[-3000:])
                self.assertTrue(last.startswith('smoke: result=REPORT_FAILURE '), last)
                for run in ('cj-home', 'cj-sibling', 'cj-outside'):
                    label = 'report' if run == 'cj-outside' else 'fallback-report'
                    state = 'missing' if mode == 'missing-report' else 'unchanged'
                    self.assertIn(f'{run}:{label}-{state}', last)
                self.assertEqual(out.count('  | report-valid=false\n'), 3)
                self.assertEqual(out.count('launcher exit 65'), 3)

    def test_existing_report_denied_and_failed_replacement_are_named_failures(self):
        for mode in ('existing-report-denied', 'rewrite-denied'):
            with self.subTest(mode=mode):
                rc, last, out = self.run_smoke(self.shm / 'td', '--stub', mode)
                self.assertEqual(rc, 1, out[-3000:])
                self.assertTrue(last.startswith('smoke: result=REPORT_FAILURE '), last)
                self.assertIn(' unexpected=none ', last)
                self.assertIn('cj-outside', last.split(' enforced=')[1].split(' ')[0])
                for run in ('cj-home', 'cj-sibling'):
                    self.assertIn(f'{run}:fallback-report-empty', last)
                self.assertEqual(out.count('  | report-valid=false\n'), 2)
                self.assertEqual(out.count('  | report-valid=true\n'), 1)
                self.assertEqual(out.count('  | control ./smoke-control.txt: WROTE\n'), 14)
                if mode == 'existing-report-denied':
                    self.assertEqual(len(re.findall(r'\| report /[^\n]+/REPORT\.txt: refused:', out)), 4)
                else:
                    self.assertEqual(out.count('stub: replacement refused; new file allowed'), 2)
                    self.assertEqual(len(re.findall(r'\| report /[^\n]+/REPORT\.txt: WROTE\n', out)), 6)

    def test_completed_launcher_probe_with_nonzero_or_timeout_never_passes(self):
        for mode, reason, code in (('cj-fail', 'code-job-exit-7', 7), ('cj-timeout', 'timeout', 124)):
            with self.subTest(mode=mode):
                rc, last, out = self.run_smoke(self.shm / 'td', '--stub', mode)
                self.assertEqual(rc, 0, out[-3000:])
                self.assertTrue(last.startswith('smoke: result=INCONCLUSIVE '), last)
                for run in ('cj-home', 'cj-sibling', 'cj-outside'):
                    self.assertIn(f'{run}:{reason}', last)
                self.assertEqual(out.count(f'completion marker: written; exit: {code}'), 3)


# Real bytecode as Xcode's python3 writes it (sys.pycache_prefix: no __pycache__, mirrored source dirs), a CFPreferences
# plist, and a python3 shim that forces Apple's prefix whatever the environment says (-X overrides PYTHONPYCACHEPREFIX).
OS_LIBRARY = ('env -u PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX="$HOME/Library/Caches/com.apple.python" '
              'python3 -c "import json" && mkdir -p "$HOME/Library/Preferences" && '
              'printf bplist00 > "$HOME/Library/Preferences/com.apple.python3.plist"\n')
XCODE_PYTHON = '#!/bin/sh\nexec {env}{python} -X pycache_prefix="$HOME/Library/Caches/com.apple.python" "$@"\n'


@unittest.skipIf(os.geteuid() == 0, "the stub denies writes with permission bits, which root ignores")
@unittest.skipUnless(shutil.which("python3"), "needs python3")
class OsLibraryTests(unittest.TestCase):
    """mactest1/2: HOME stays empty under an Xcode-like python3; an OS-made Library passes only in its exact shapes."""
    setUp = SmokeStubTests.setUp
    run_smoke = SmokeStubTests.run_smoke

    def xcode_python(self, honour_env=True):
        shim = self.shm / ("xcode-bin" if honour_env else "xcode-bin-writes")
        shim.mkdir()
        env = "" if honour_env else "env -u PYTHONDONTWRITEBYTECODE "
        (shim / "python3").write_text(XCODE_PYTHON.format(env=env, python=shlex.quote(shutil.which("python3"))))
        (shim / "python3").chmod(0o755)
        return shim

    def wrapped(self, after=""):
        # The real smoke plus the OS's Library, then an optional leak.
        wrapper = self.shm / "wrap.sh"
        wrapper.write_text(f'{OS_LIBRARY}sh {shlex.quote(str(SCRIPT))} "$@"; rc=$?\n{after}\nexit $rc\n')
        return wrapper

    def os_library(self):
        subprocess.run(["sh", "-c", OS_LIBRARY], env={**os.environ, "HOME": str(self.home)}, check=True)
        library = self.home / "Library"
        self.assertEqual(os_library_problems(library, [os.fsencode(str(self.shm))], (self.shm,)), [])
        return library

    def test_xcode_like_python3_leaves_home_empty(self):
        # The Mac symptom reproduced on any host: a python3 that always writes bytecode under ~/Library/Caches.
        with patch.object(sys.modules[__name__], "DARWIN", False):
            rc, last, out = self.run_smoke(self.shm / "td", "--stub", path=self.xcode_python())
            self.assertEqual(rc, 0, out[-3000:])
            self.assertTrue(last.startswith("smoke: result=PASS "), last)
            with self.assertRaisesRegex(AssertionError, r"(?s)\['Library'\] != \[\].*outside dir left in HOME"):
                self.run_smoke(self.shm / "td", "--stub", path=self.xcode_python(honour_env=False))

    def test_os_library_is_tolerated_only_on_darwin(self):
        shim = self.xcode_python(honour_env=False)
        with patch.object(sys.modules[__name__], "DARWIN", True):
            rc, last, out = self.run_smoke(self.shm / "td", "--stub", script=self.wrapped(), path=shim)
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=PASS "), last)
        self.assertTrue(list((self.home / "Library").rglob("*.pyc")))
        shutil.rmtree(self.home / "Library")
        with patch.object(sys.modules[__name__], "DARWIN", False), \
                self.assertRaisesRegex(AssertionError, "outside dir left in HOME"):
            self.run_smoke(self.shm / "td", "--stub", script=self.wrapped())

    def test_smoke_leaks_beside_or_inside_os_library_still_fail(self):
        cases = (('mkdir "$HOME/macsmoke1.leak"', "outside dir left in HOME"),
                 ('mkdir "$HOME/Library/Caches/macsmoke1.leak"', "smoke files in HOME/Library"),
                 ('find "$HOME/Library" -name "*.pyc" '
                  '-exec sh -c \'for f; do printf %s "$TMPDIR" >> "$f"; done\' sh {} +',
                  "smoke files in HOME/Library"),
                 ('echo "left behind" > "$HOME/Library/Caches/unexpected.txt"', "smoke files in HOME/Library"),
                 ('mkdir "$HOME/Library/Caches/session"', "smoke files in HOME/Library"))
        for after, message in cases:
            with self.subTest(after=after), patch.object(sys.modules[__name__], "DARWIN", True):
                with self.assertRaisesRegex(AssertionError, message):
                    self.run_smoke(self.shm / "td", "--stub", script=self.wrapped(after))
                for entry in self.home.iterdir():
                    shutil.rmtree(entry)

    def test_library_classifier_names_each_smoke_trace(self):
        library = self.os_library()
        markers = [os.fsencode(str(self.shm))]
        pyc = next(library.rglob("*.pyc"))
        mirror = library / "Caches/com.apple.python" / str(self.shm).lstrip("/")
        mirror.mkdir(parents=True)
        (self.shm / "mod.py").write_text("")
        (mirror / "mod.cpython-39.pyc").write_bytes(pyc.read_bytes())
        (pyc.parent / "absent.cpython-39.pyc").write_bytes(pyc.read_bytes())
        fake = pyc.parent / (pyc.name.split(".")[0] + ".cpython-39.opt-1.pyc")
        fake.write_text("x")
        (library / "Caches/com.apple.python/ok.cpython-39.pyc").write_bytes(pyc.read_bytes())
        (library / "Application Support").mkdir()
        (library / "Caches/unexpected.txt").write_text("left behind\n")
        (library / "Caches/session").mkdir()
        (library / "Caches/smoke-control.txt").write_text("x\n")
        (library / "Preferences/com.apple.fake.plist").write_text("x")
        (library / "Preferences/notes.plist").write_bytes(b"bplist00")
        (library / "Preferences/link").symlink_to(self.shm, target_is_directory=True)
        os.mkfifo(library / "Preferences/com.apple.fifo.plist")
        with (library / "Preferences/com.apple.python3.plist").open("ab") as plist:
            plist.write(os.fsencode(str(self.shm)) + b"/td/x\n")
        pyc_dir = pyc.parent.relative_to(library)
        self.assertEqual(sorted(os_library_problems(library, markers, (self.shm,))), sorted([
            "Application Support: empty directory",
            f"{mirror.relative_to(library)}/mod.cpython-39.pyc: bytecode of a fixture source",
            f"{pyc_dir}/absent.cpython-39.pyc: bytecode without a real source",
            f"{pyc_dir}/{fake.name}: not CPython bytecode",
            "Caches/com.apple.python/ok.cpython-39.pyc: not an OS-owned file",
            "Caches/session: empty directory",
            "Caches/smoke-control.txt: not an OS-owned file",
            "Caches/unexpected.txt: not an OS-owned file",
            "Preferences/com.apple.fake.plist: not a property list",
            "Preferences/com.apple.fifo.plist: not a regular file or directory",
            "Preferences/com.apple.python3.plist: mentions a smoke fixture path",
            "Preferences/link: not a regular file or directory",
            "Preferences/notes.plist: not an OS-owned file"]))
        shutil.rmtree(library)
        library.mkdir()
        self.assertEqual(os_library_problems(library, markers), ["Library: empty directory"])
        library.rmdir()
        library.symlink_to(self.shm, target_is_directory=True)
        self.assertEqual(os_library_problems(library, markers), ["Library: not a plain directory"])
        library.unlink()

    def test_unreadable_library_fails_closed(self):
        library = self.os_library()
        locked = library / "Caches/locked"
        locked.mkdir()
        (locked / "com.apple.x.plist").write_bytes(b"bplist00")
        locked.chmod(0)
        self.addCleanup(locked.chmod, 0o700)
        self.assertEqual(os_library_problems(library, []), ["Caches/locked: unreadable (Permission denied)"])
        locked.chmod(0o700)
        (library / "Preferences/com.apple.python3.plist").chmod(0)
        self.assertEqual(os_library_problems(library, []),
                         ["Caches/locked/com.apple.x.plist: not an OS-owned file",
                          "Preferences/com.apple.python3.plist: unreadable (Permission denied)"])
        with patch.object(os, "scandir", side_effect=PermissionError(13, "Permission denied", str(library))):
            self.assertEqual(os_library_problems(library, []), ["Library: unreadable (Permission denied)"])


if __name__ == "__main__":
    unittest.main()
