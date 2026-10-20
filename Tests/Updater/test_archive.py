"""P0b: the archive extractor never writes outside its target (Resources/Updater/swarmhub_update/archive.py).

Each unsafe archive (traversal, absolute path, links, devices, FIFOs, bad modes, oversize, unsupported entries) is
refused before anything is written, a symlink planted in the target is never followed, and extracting the P0a
bundle leaves a Hermes stand-in byte-identical. Archives are built here, not with scripts/release/ustar.py, so
this suite does not load the P0a reference code.

    python3 -m unittest discover -s Tests/Updater
"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources/Updater"))

from swarmhub_update import archive, verify  # noqa: E402

FIXTURES = ROOT / "Tests/Fixtures/release-bundles"
HERMES = ROOT / "Tests/Fixtures/hermes_v0.21.7_server.py"
LIMITS = dict(verify.DEFAULT_LIMITS)
FLAGS = {"file": "0", "hardlink": "1", "symlink": "2", "char": "3", "block": "4", "dir": "5", "fifo": "6",
         "pax": "x", "gnu-long": "L"}


def header(name, mode, size, kind, linkname=""):
    raw = name.encode("utf-8")
    prefix = b""
    if len(raw) > 100:
        cut = raw.rindex(b"/", 0, 156)
        prefix, raw = raw[:cut], raw[cut + 1:]

    def octal(value, width):
        return format(value, "o").encode().rjust(width - 1, b"0") + b"\0"
    block = bytearray(raw.ljust(100, b"\0") + octal(mode, 8) + octal(0, 8) + octal(0, 8) + octal(size, 12)
                      + octal(0, 12) + b" " * 8 + FLAGS[kind].encode() + linkname.encode().ljust(100, b"\0")
                      + b"ustar\0" + b"00" + b"\0" * 64 + octal(0, 8) + octal(0, 8) + prefix.ljust(155, b"\0")
                      + b"\0" * 12)
    block[148:156] = format(sum(block), "06o").encode() + b"\0 "
    return bytes(block)


def tar(*entries):
    """entries: (name, kind, mode[, data or linkname])."""
    out = bytearray()
    for name, kind, mode, *rest in entries:
        data = rest[0] if rest and kind not in ("symlink", "hardlink") else b""
        linkname = rest[0] if rest and kind in ("symlink", "hardlink") else ""
        out += header(name, mode, len(data), kind, linkname) + data
        out += b"\0" * (-len(data) % 512)
    return bytes(out + b"\0" * 1024)


SKILL = ("SKILL.md", "file", 0o644, b"---\nname: t\n---\nTEST\n")
UNSAFE = {  # case: (archive, expected reason, limits override)
    "dotdot": (tar(SKILL, ("../evil.sh", "file", 0o755, b"#!/bin/sh\n")), "archive_unsafe_path", {}),
    "dotdot-nested": (tar(SKILL, ("scripts/../../evil", "file", 0o644, b"x")), "archive_unsafe_path", {}),
    "absolute": (tar(SKILL, ("/tmp/evil.sh", "file", 0o755, b"#!/bin/sh\n")), "archive_unsafe_path", {}),
    "dot": (tar(SKILL, ("./SKILL2.md", "file", 0o644, b"x")), "archive_unsafe_path", {}),
    "empty-segment": (tar(SKILL, ("a//b.md", "file", 0o644, b"x")), "archive_unsafe_path", {}),
    "trailing-newline": (tar(SKILL, ("notes.md\n", "file", 0o644, b"x")), "archive_unsafe_path", {}),
    "backslash": (tar(SKILL, ("..\\evil", "file", 0o644, b"x")), "archive_unsafe_path", {}),
    "too-deep": (tar(SKILL, ("a/b/c/d.md", "file", 0o644, b"x")), "archive_unsafe_path", {"max_depth": 3}),
    "too-long": (tar(SKILL, ("n" * 40 + ".md", "file", 0o644, b"x")), "archive_unsafe_path", {"max_path_bytes": 32}),
    "symlink": (tar(SKILL, ("scripts", "symlink", 0o777, "/etc")), "archive_link", {}),
    "symlink-then-file": (tar(("out", "symlink", 0o777, ".."), ("out/evil", "file", 0o644, b"x")), "archive_link", {}),
    "hardlink": (tar(SKILL, ("hard", "hardlink", 0o644, "/etc/passwd")), "archive_link", {}),
    "char-device": (tar(SKILL, ("dev", "char", 0o644)), "archive_special_file", {}),
    "block-device": (tar(SKILL, ("blk", "block", 0o644)), "archive_special_file", {}),
    "fifo": (tar(SKILL, ("pipe", "fifo", 0o644)), "archive_special_file", {}),
    "pax": (tar(("pax", "pax", 0o644, b"30 path=../../../../etc/evil\n"), SKILL), "archive_unsupported_entry", {}),
    "gnu-long": (tar(("././@LongLink", "gnu-long", 0o644, b"../evil\0"), SKILL), "archive_unsupported_entry", {}),
    "setuid": (tar(SKILL, ("run", "file", 0o4755, b"#!/bin/sh\n")), "archive_bad_mode", {}),
    "world-writable": (tar(("SKILL.md", "file", 0o666, b"x")), "archive_bad_mode", {}),
    "dir-mode": (tar(("scripts/", "dir", 0o777)), "archive_bad_mode", {}),
    "oversize-file": (tar(SKILL, ("big.md", "file", 0o644, b"b" * 5000)), "archive_oversize", {"max_file_size": 4096}),
    "oversize-total": (tar(SKILL, ("a.md", "file", 0o644, b"a" * 900), ("b.md", "file", 0o644, b"b" * 900)),
                       "archive_oversize", {"max_total_size": 1500}),
    "too-many-entries": (tar(*[(f"f{i}.md", "file", 0o644, b"x") for i in range(6)]), "archive_oversize",
                         {"max_entries": 5}),
    "duplicate": (tar(SKILL, SKILL), "archive_duplicate_path", {}),
    "file-as-parent": (tar(("scripts", "file", 0o644, b"x"), ("scripts/run", "file", 0o755, b"x")),
                       "archive_path_conflict", {}),
    "truncated": (tar(SKILL)[:600], "archive_malformed", {}),
    "trailing-garbage": (tar(SKILL) + b"junk", "archive_malformed", {}),
}


def snapshot(directory):
    """Every path below directory (never following links) with its type, mode and content hash or link target."""
    found = {}
    for current, dirs, files in os.walk(directory, followlinks=False):
        for name in dirs + files:
            path = os.path.join(current, name)
            info = os.lstat(path)
            if stat.S_ISLNK(info.st_mode):
                detail = os.readlink(path)
            elif stat.S_ISREG(info.st_mode):
                detail = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            else:
                detail = ""
            found[os.path.relpath(path, directory)] = (stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), detail)
    return found


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = Path(tempfile.mkdtemp(prefix="p0b-extract-"))
        self.addCleanup(shutil.rmtree, self.sandbox)
        self.outside = self.sandbox / "outside"
        self.outside.mkdir()
        (self.outside / "keep.txt").write_bytes(b"outside\n")
        self.stage = self.sandbox / "stage"
        self.stage.mkdir()
        self.target = self.stage / "component"

    def test_valid_archive_is_written_with_exact_modes_under_any_umask(self):
        data = tar(SKILL, ("scripts/", "dir", 0o755), ("scripts/run", "file", 0o755, b"#!/bin/sh\necho TEST\n"),
                   ("docs/deep/notes.md", "file", 0o644, b"notes\n"))
        old = os.umask(0o077)
        try:
            needs_code = archive.extract(data, "skill", LIMITS, self.target)
        finally:
            os.umask(old)
        self.assertTrue(needs_code)
        found = snapshot(self.target)
        self.assertEqual({k: v[:2] for k, v in found.items()}, {
            "SKILL.md": (stat.S_IFREG, 0o644), "scripts": (stat.S_IFDIR, 0o755),
            "scripts/run": (stat.S_IFREG, 0o755), "docs": (stat.S_IFDIR, 0o755),
            "docs/deep": (stat.S_IFDIR, 0o755), "docs/deep/notes.md": (stat.S_IFREG, 0o644)})
        self.assertEqual(stat.S_IMODE(os.stat(self.target).st_mode), 0o755)
        self.assertEqual((self.target / "scripts/run").read_bytes(), b"#!/bin/sh\necho TEST\n")
        self.assertEqual(sorted(p.name for p in self.sandbox.iterdir()), ["outside", "stage"])

    def test_markdown_only_skill_is_data(self):
        self.assertFalse(archive.extract(tar(SKILL), "skill", LIMITS, self.target))

    def test_extension_rule_matches_the_reference_suffix(self):
        for name in ("a.md", "..md", ".md", "b.", "a/b.c.json", "x", "a.b/c", "a/.hidden.txt", "...", "a.."):
            self.assertEqual(archive.extension(name), PurePosixPath(name).suffix, name)
        self.assertFalse(archive.check(tar(("..md", "file", 0o644, b"x")), "skill", LIMITS)[1])
        self.assertTrue(archive.check(tar((".md", "file", 0o644, b"x")), "skill", LIMITS)[1])

    def test_unsafe_archives_are_refused_before_any_write(self):
        before = snapshot(self.sandbox)
        absolute = str(self.outside / "abs-evil.sh")  # absolute name inside the sandbox, so a write would show
        cases = dict(UNSAFE, **{"absolute-in-sandbox": (tar(SKILL, (absolute, "file", 0o644, b"x")),
                                                       "archive_unsafe_path", {})})
        for case, (data, reason, override) in cases.items():
            with self.subTest(case):
                with self.assertRaises(archive.ArchiveError) as caught:
                    archive.extract(data, "skill", dict(LIMITS, **override), self.target)
                self.assertEqual(caught.exception.reason, reason)
                self.assertFalse(os.path.lexists(self.target))
                self.assertEqual(snapshot(self.sandbox), before)

    def test_existing_target_or_symlinked_target_is_refused(self):
        os.symlink(self.outside, self.target)
        before = snapshot(self.sandbox)
        with self.assertRaises(FileExistsError):
            archive.extract(tar(SKILL), "skill", LIMITS, self.target)
        self.assertEqual(snapshot(self.sandbox), before)

    def test_symlink_planted_in_target_is_never_followed(self):
        os.mkdir(self.target)
        os.symlink(self.outside, self.target / "scripts")
        os.symlink(self.outside / "keep.txt", self.target / "SKILL.md")
        before = snapshot(self.outside)
        entries, _ = archive.check(tar(("scripts/run", "file", 0o755, b"x")), "skill", LIMITS)
        root = os.open(self.target, os.O_RDONLY)
        try:
            with self.assertRaises(OSError):
                archive.write_entries(root, entries)
            entries, _ = archive.check(tar(SKILL), "skill", LIMITS)
            with self.assertRaises(FileExistsError):
                archive.write_entries(root, entries)
        finally:
            os.close(root)
        self.assertEqual(snapshot(self.outside), before)

    def test_writer_refuses_unchecked_unsafe_names(self):
        os.mkdir(self.target)
        root = os.open(self.target, os.O_RDONLY)
        try:
            for name in ("../evil", "/abs", "a/../../evil", "ok\n"):
                with self.subTest(name), self.assertRaises(archive.ArchiveError):
                    archive.write_entries(root, [{"name": name, "typeflag": "0", "mode": 0o644, "data": b"x"}])
        finally:
            os.close(root)
        self.assertEqual(os.listdir(self.target), [])
        self.assertEqual(sorted(os.listdir(self.sandbox)), ["outside", "stage"])


class BundleExtractTests(unittest.TestCase):
    def test_accepted_vectors_extract_exactly_their_entries_and_leave_hermes_byte_identical(self):
        sandbox = Path(tempfile.mkdtemp(prefix="p0b-hermes-"))
        self.addCleanup(shutil.rmtree, sandbox)
        hermes = sandbox / "hermes-agent/hermes/server.py"
        hermes.parent.mkdir(parents=True)
        shutil.copyfile(HERMES, hermes)
        skills = sandbox / "profile/skills/swarmhub"
        skills.mkdir(parents=True)
        outside_before = snapshot(sandbox)
        vectors = json.loads((FIXTURES / "vectors.json").read_text(encoding="utf-8"))
        accepted = [c for c in vectors["cases"] if c["expect"]["verdict"] == "accept"]
        self.assertEqual(len(accepted), 6)
        written = 0
        for case in accepted:
            inputs = case["inputs"]
            verdict = verify.verify_release(
                *[(FIXTURES / inputs[k]).read_bytes() for k in ("pins", "keys", "index")],
                fetch_manifest=lambda line: (FIXTURES / inputs["manifest"]).read_bytes(),
                fetch_blob=lambda c: (FIXTURES / "blobs/sha256" / c["sha256"]).read_bytes(),
                channel=inputs["channel"], now=inputs["now"], floors=inputs["floors"], consumer=inputs["consumer"],
                install_id=inputs["install_id"], revoked_key_ids=inputs["revoked_key_ids"], limits=inputs["limits"])
            staging = skills / f".staging-{case['id']}"
            staging.mkdir()
            for component in verdict["manifest"]["components"]:
                if component["name"] not in verdict["blobs"]:
                    continue
                target = staging / component["path"]
                archive.extract(verdict["blobs"][component["name"]], component["kind"], inputs["limits"], target)
                entries, _ = archive.check(verdict["blobs"][component["name"]], component["kind"], inputs["limits"])
                for entry in entries:
                    path = target / entry["name"]
                    self.assertEqual(path.is_dir(), entry["typeflag"] == "5")
                    if entry["typeflag"] == "0":
                        self.assertEqual(path.read_bytes(), entry["data"])
                        self.assertEqual(stat.S_IMODE(path.stat().st_mode), entry["mode"])
                written += 1
        self.assertEqual(written, 20)
        after = {k: v for k, v in snapshot(sandbox).items() if ".staging-" not in k}
        self.assertEqual(after, outside_before)
        self.assertEqual(hashlib.sha256(hermes.read_bytes()).digest(), hashlib.sha256(HERMES.read_bytes()).digest())


if __name__ == "__main__":
    unittest.main()
