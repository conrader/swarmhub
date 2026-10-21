"""Darwin Library regressions, also runnable on Linux without providers or network."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import importlib.util
import marshal
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

try:
    from sim import test_macsmoke2 as smoke
    from sim.macsmoke_library import ROOT, PYC_PREFIX, os_library_file, os_library_problems
except ImportError:
    import test_macsmoke2 as smoke
    from macsmoke_library import ROOT, PYC_PREFIX, os_library_file, os_library_problems

SCRIPT = smoke.SCRIPT


# Real bytecode as Xcode's python3 writes it (sys.pycache_prefix: no __pycache__, mirrored source dirs), a CFPreferences
# plist, and a python3 shim that forces Apple's prefix whatever the environment says (-X overrides PYTHONPYCACHEPREFIX).
OS_LIBRARY = ('env -u PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX="$HOME/Library/Caches/com.apple.python" '
              'python3 -c "import json" && mkdir -p "$HOME/Library/Preferences" && '
              'printf \'%s\\n\' \'<plist version="1.0"><dict/></plist>\' '
              '> "$HOME/Library/Preferences/com.apple.python3.plist"\n')
XCODE_PYTHON = '#!/bin/sh\nexec {env}{python} -X pycache_prefix="$HOME/Library/Caches/com.apple.python" "$@"\n'


@unittest.skipIf(os.geteuid() == 0, "the stub denies writes with permission bits, which root ignores")
@unittest.skipUnless(shutil.which("python3"), "needs python3")
class OsLibraryTests(unittest.TestCase):
    """mactest1/2: HOME stays empty under an Xcode-like python3; an OS-made Library passes only in its exact shapes."""
    setUp = smoke.SmokeStubTests.setUp
    run_smoke = smoke.SmokeStubTests.run_smoke

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
        with patch.object(smoke, "DARWIN", False):
            rc, last, out = self.run_smoke(self.shm / "td", "--stub", path=self.xcode_python())
            self.assertEqual(rc, 0, out[-3000:])
            self.assertTrue(last.startswith("smoke: result=PASS "), last)
            with self.assertRaisesRegex(AssertionError, r"(?s)\['Library'\] != \[\].*outside dir left in HOME"):
                self.run_smoke(self.shm / "td", "--stub", path=self.xcode_python(honour_env=False))

    def test_os_library_is_tolerated_only_on_darwin(self):
        shim = self.xcode_python(honour_env=False)
        with patch.object(smoke, "DARWIN", True):
            rc, last, out = self.run_smoke(self.shm / "td", "--stub", script=self.wrapped(), path=shim)
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=PASS "), last)
        self.assertTrue(list((self.home / "Library").rglob("*.pyc")))
        shutil.rmtree(self.home / "Library")
        with patch.object(smoke, "DARWIN", False), \
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
            with self.subTest(after=after), patch.object(smoke, "DARWIN", True):
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
        (library / "Preferences/com.apple.python3.plist").write_bytes(plistlib.dumps({"path": str(self.shm / "td/x")}))
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
        preferences = library / "Preferences/com.apple.python3.plist"
        # CFPreferences' exact Mac path, with both supported encodings. The contents
        # are representative preferences, not a capture from the inaccessible Mac.
        walk = os.walk

        def ordered_walk(*args, **kwargs):
            for root, dirs, files in walk(*args, **kwargs):
                dirs.sort(reverse=preferences_first)
                yield root, dirs, files

        locked = library / "Caches/locked"
        locked.mkdir()
        (locked / "com.apple.x.plist").write_bytes(b"bplist00")
        locked.chmod(0)
        self.addCleanup(locked.chmod, 0o700)
        self.assertEqual(os_library_problems(library, []), ["Caches/locked: unreadable (Permission denied)"])
        locked.chmod(0o700)
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            preferences.chmod(0o600)
            preferences.write_bytes(plistlib.dumps({"AppleLanguages": ["en-US"], "AppleLocale": "en_US"}, fmt=fmt))
            for preferences_first in (False, True):
                with self.subTest(fmt=fmt, preferences_first=preferences_first), patch.object(os, "walk", ordered_walk):
                    preferences.chmod(0o600)
                    self.assertEqual(os_library_problems(library, []),
                                     ["Caches/locked/com.apple.x.plist: not an OS-owned file"])
                    preferences.chmod(0)
                    # Filesystem enumeration order varies (APFS can visit Preferences first).
                    # Require exactly both errors, including multiplicity, in either order.
                    self.assertCountEqual(os_library_problems(library, []),
                                          ["Caches/locked/com.apple.x.plist: not an OS-owned file",
                                           "Preferences/com.apple.python3.plist: unreadable (Permission denied)"])
        with patch.object(os, "scandir", side_effect=PermissionError(13, "Permission denied", str(library))):
            self.assertEqual(os_library_problems(library, []), ["Library: unreadable (Permission denied)"])


class LibraryFileValidationTests(unittest.TestCase):
    """mactest3: exercise the Darwin classifier directly on Linux, without launching a provider."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="mactest4-", dir="/tmp")
        self.addCleanup(tmp.cleanup)
        # Simulate macOS /tmp -> /private/tmp on every host, including Linux.
        root = Path(tmp.name)
        physical = root / "private/tmp"
        physical.mkdir(parents=True)
        self.external = root / "tmp"
        self.external.symlink_to(physical, target_is_directory=True)
        self.source = self.external / "mod.py"
        self.source.write_text("")
        self.rel = (Path(*PYC_PREFIX) / str(self.external).lstrip("/") /
                    f"mod.{sys.implementation.cache_tag}.pyc")
        self.fixtures = {f for p in (ROOT, self.external / "fixture")
                         for f in (str(p), os.path.realpath(p))}

    def bytecode(self, filename=None, flags=0):
        source_stat = self.source.stat()
        stamp = ((int(source_stat.st_mtime) & 0xffffffff).to_bytes(4, "little") +
                 (source_stat.st_size & 0xffffffff).to_bytes(4, "little"))
        return (importlib.util.MAGIC_NUMBER + flags.to_bytes(4, "little") + stamp +
                marshal.dumps(compile("", str(filename or self.source), "exec")))

    def test_malformed_plist_and_crlf_garbage_are_rejected(self):
        for data in (b"<?xml left behind", b"<plist left behind", b"bplist00"):
            with self.subTest(data=data):
                self.assertIsNotNone(os_library_file(Path("Preferences/com.apple.test.plist"), data, self.fixtures))
        self.assertIsNotNone(os_library_file(self.rel, b"xx\r\nleft behind!!", self.fixtures))

    def test_external_source_symlinks_into_repo_or_fixture_are_rejected(self):
        fixture = self.external / "fixture"
        fixture.mkdir()
        (fixture / "mod.py").write_text("")
        for target in (ROOT / "sim/test_macsmoke2.py", fixture / "mod.py"):
            with self.subTest(target=target):
                self.source.unlink()
                self.source.symlink_to(target)
                self.assertEqual(os_library_file(self.rel, self.bytecode(), self.fixtures),
                                 "bytecode of a fixture source")

    def test_plist_formats_and_encoded_fixture_paths(self):
        rel = Path("Preferences/com.apple.test.plist")
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt):
                self.assertIsNone(os_library_file(rel, plistlib.dumps({"ok": True}, fmt=fmt), self.fixtures))
                for path in self.fixtures:
                    # The non-ASCII value uses UTF-16 in a binary plist; raw UTF-8 scanning misses it.
                    for value in ({"nested": ["é " + path]}, {path: True}, {"data": os.fsencode(path)}):
                        self.assertIsNotNone(os_library_file(rel, plistlib.dumps(value, fmt=fmt), self.fixtures))
        cycle = [str(ROOT)]
        cycle.append(cycle)
        self.assertIsNotNone(os_library_file(rel, plistlib.dumps(cycle, fmt=plistlib.FMT_BINARY), self.fixtures))

    def test_bytecode_header_payload_and_source_mapping(self):
        for flags in (0, 1, 3):
            self.assertIsNone(os_library_file(self.rel, self.bytecode(flags=flags), self.fixtures))
        valid = self.bytecode()
        other = self.external / "other.py"
        other.write_text("")
        for data in (b"xx" + valid[2:], valid[:15], self.bytecode(flags=2), self.bytecode(flags=4),
                     valid[:16], valid[:16] + marshal.dumps("not code"), valid + b"left behind",
                     self.bytecode(other), self.bytecode("mod.py")):
            with self.subTest(data=data[:24]):
                self.assertIsNotNone(os_library_file(self.rel, data, self.fixtures))
        self.source.unlink()
        for target in (self.external / "missing.py", self.source):
            with self.subTest(target=target):
                self.source.symlink_to(target)
                self.assertIsNotNone(os_library_file(self.rel, valid, self.fixtures))
                self.source.unlink()

    def pyc314(self, flags=0, code_type=b"c", constants=(None,)):
        # Synthetic 3.14 code record, independent of the host's CodeType layout.
        # Field order: CPython v3.14.0/Python/marshal.c (PyCode_Check branch).
        # Opcodes: v3.14.0/Include/opcode_ids.h: RESUME, LOAD_CONST, RETURN_VALUE.
        fields = (bytes((128, 0, 82, 0, 35, 0)), constants, (), (), b"",
                  str(self.source), "<module>", "<module>")
        payload = (code_type + struct.pack("<5i", 0, 0, 0, 1, 0) +
                   b"".join(marshal.dumps(value, 2) for value in fields) +
                   struct.pack("<i", 1) + marshal.dumps(b"", 2) * 2)
        return (struct.pack("<H2sI", 3627, b"\r\n", flags) +
                self.bytecode()[8:16] + payload)

    def test_newer_cpython314_cache_passes_without_cross_version_marshal(self):
        for flags in (0, 1, 3):
            for code_type in (b"c", b"\xe3"):
                data = self.pyc314(flags, code_type)
                for opt in ("", ".opt-1", ".opt-2"):
                    rel = self.rel.with_name(f"mod.cpython-314{opt}.pyc")
                    with self.subTest(flags=flags, code_type=code_type, opt=opt):
                        self.assertIsNone(os_library_file(rel, data, self.fixtures))
                        if sys.implementation.cache_tag != "cpython-314":
                            with patch.object(marshal, "load", side_effect=AssertionError("foreign marshal")) as load:
                                self.assertIsNone(os_library_file(rel, data, self.fixtures))
                                load.assert_not_called()
        library = self.external / "Library"
        cache = library / self.rel.with_name("mod.cpython-314.pyc")
        cache.parent.mkdir(parents=True)
        cache.write_bytes(self.pyc314())
        self.assertEqual(os_library_problems(library, [], self.fixtures), [])
        cache.write_bytes(self.pyc314(constants=(None, b"smoke-marker")))
        self.assertIn("mentions a smoke fixture path", os_library_problems(library, [b"smoke-marker"])[0])

    def test_newer_cache_rejects_malformed_headers_payloads_and_names(self):
        rel = self.rel.with_name("mod.cpython-314.pyc")
        valid = self.pyc314()
        invalid = [b"garbage", struct.pack("<H", 3571) + valid[2:],
                   valid[:2] + b"\n\r" + valid[4:], b"xx" + valid[2:],
                   valid[:16] + marshal.dumps("not code"), valid[:16] + b"x" * 128]
        invalid += [valid[:n] for n in range(17)]
        invalid += [valid[:16] + b"c" + bytes(n) for n in (0, 1, 15, 30)]
        invalid += [valid[:4] + struct.pack("<I", flag) + valid[8:] for flag in (2, 4, 0xffffffff)]
        invalid += [valid[:offset] + struct.pack("<I", int.from_bytes(valid[offset:offset+4], "little") ^ 1) +
                    valid[offset+4:] for offset in (8, 12)]
        for data in invalid:
            with self.subTest(data=data[:24], size=len(data)):
                self.assertIsNotNone(os_library_file(rel, data, self.fixtures))
        for tag in ("cpython-313", "cpython-315", "cpython-399", "cpython-0314", "cpython-314t",
                    "pypy-314", "pypy314", "cpython-314.opt-0", "cpython-314.opt-3",
                    "cpython-314.opt-01", "cpython-314.opt-", "cpython-314.opt-1.extra"):
            with self.subTest(tag=tag):
                self.assertIsNotNone(os_library_file(rel.with_name(f"mod.{tag}.pyc"), valid, self.fixtures))

    def test_known_magic_boundaries_and_unissued_numbers(self):
        # Independent expected values catch accidental widening to reserved ranges.
        for tag, low, high in (("38", 3400, 3413), ("39", 3420, 3425), ("310", 3430, 3439),
                               ("311", 3450, 3495), ("312", 3500, 3531), ("313", 3550, 3571),
                               ("314", 3600, 3627)):
            rel = self.rel.with_name(f"mod.cpython-{tag}.pyc")
            for magic in (low, high, low - 1, high + 1):
                with self.subTest(tag=tag, magic=magic):
                    data = struct.pack("<H", magic) + self.pyc314()[2:]
                    if f"cpython-{tag}" == sys.implementation.cache_tag:
                        # A compatible magic alone must never bypass native marshal.
                        data = data[:16] + b"c" + bytes(64)
                        self.assertIsNotNone(os_library_file(rel, data, self.fixtures))
                    else:
                        self.assertEqual(os_library_file(rel, data, self.fixtures) is None,
                                         magic in (low, high))
        for magic in (3402, 3409):
            data = struct.pack("<H", magic) + self.pyc314()[2:]
            self.assertIsNotNone(os_library_file(self.rel.with_name("mod.cpython-38.pyc"), data, self.fixtures))

    def test_newer_cache_source_and_io_checks_fail_closed(self):
        rel = self.rel.with_name("mod.cpython-314.pyc")
        valid = self.pyc314()
        fixture = self.external / "fixture"
        fixture.mkdir()
        target = fixture / "mod.py"
        target.write_text("")
        fixture_rel = Path(*PYC_PREFIX) / str(target.parent).lstrip("/") / rel.name
        self.assertEqual(os_library_file(fixture_rel, valid, self.fixtures), "bytecode of a fixture source")
        for path in self.fixtures:
            self.assertEqual(os_library_file(rel, valid + os.fsencode(path), self.fixtures),
                             "mentions a smoke fixture path")
        with patch.object(os, "stat", side_effect=PermissionError):
            self.assertIsNotNone(os_library_file(rel, valid, self.fixtures))
        library = self.external / "Library"
        cache = library / rel
        cache.parent.mkdir(parents=True)
        cache.write_bytes(valid)
        with patch.object(Path, "read_bytes", side_effect=PermissionError(13, "Permission denied")):
            self.assertIn("unreadable", os_library_problems(library, [])[0])
        self.source.unlink()
        for dest in (target, ROOT / "sim/test_macsmoke2.py", self.external / "missing", self.source):
            self.source.symlink_to(dest)
            self.assertIsNotNone(os_library_file(rel, valid, self.fixtures))
            self.source.unlink()
        self.assertIsNotNone(os_library_file(rel, valid, self.fixtures))
        self.source.mkdir()
        self.assertIsNotNone(os_library_file(rel, valid, self.fixtures))


if __name__ == "__main__":
    unittest.main()
