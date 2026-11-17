import contextlib
import errno
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("workspace_manifest", ROOT / "scripts/workspace-manifest.py")
manifests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifests)


def fragment(target="x86_64-linux", version="0.2.1", name=None, api=1):
    return {"product": "swarmhub-herdr", "version": version, "api": api, "api_min": 1,
            "asset": {"target": target, "name": name or f"swarmhub-herdr-{version}-{target}", "size": 3, "sha256": "ab" * 32}}


# The first bytes of a program file, per kind of machine: 64-bit Mach-O (magic, CPU type) and ELF (ident, type, machine).
HEADERS = {"x86_64-macos": bytes.fromhex("cffaedfe07000001"), "aarch64-macos": bytes.fromhex("cffaedfe0c000001"),
           "x86_64-linux": b"\x7fELF\x02\x01\x01" + bytes(9) + bytes.fromhex("02003e00"),
           "aarch64-linux": b"\x7fELF\x02\x01\x01" + bytes(9) + bytes.fromhex("0200b700")}


def program(folder, target, version="0.2.1", api=1):
    """A stand-in for a build this machine runs: a script that reports what a server of `target` would."""
    path = Path(folder) / f"swarmhub-herdr-{version}-{target}"
    path.write_text(f'#!/bin/sh\necho \'{{"version":"{version}","api":{api},"api_min":1,"target":"{target}","updates":true}}\'\n')
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def foreign(folder, target, version="0.2.1"):
    """A stand-in for a build this machine cannot run: only the header of a program for `target`."""
    path = Path(folder) / f"swarmhub-herdr-{version}-{target}"
    path.write_bytes(HEADERS[target] + bytes(64))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


class WorkspaceManifestTests(unittest.TestCase):
    def test_a_fragment_is_what_the_program_says_and_what_its_bytes_are(self):
        with tempfile.TemporaryDirectory() as folder:
            program = Path(folder) / "swarmhub-herdr-0.2.1-x86_64-linux"
            program.write_text('#!/bin/sh\necho \'{"version":"0.2.1","api":2,"api_min":1,"target":"x86_64-linux","updates":true}\'\n')
            program.chmod(program.stat().st_mode | stat.S_IXUSR)
            manifests.main(["asset", str(program)])
            made = json.loads((Path(folder) / (program.name + ".asset.json")).read_text())
            self.assertEqual((made["version"], made["api"], made["asset"]["target"], made["asset"]["size"]), ("0.2.1", 2, "x86_64-linux", program.stat().st_size))
            self.assertEqual(made, manifests.describe(program))

    def test_a_manifest_joins_the_builds_of_one_version(self):
        made = manifests.join([fragment("x86_64-linux"), fragment("aarch64-linux")], "v0.7.1", " Faster starts. ", "2026-11-17")
        self.assertEqual((made["product"], made["version"], made["api"], made["api_min"]), ("swarmhub-herdr", "0.2.1", 1, 1))
        self.assertEqual(made["base"], "https://github.com/conrader/swarmhub/releases/download/v0.7.1/")
        self.assertEqual([asset["target"] for asset in made["assets"]], ["aarch64-linux", "x86_64-linux"])
        self.assertEqual(made["notes"], "Faster starts.")
        self.assertEqual(manifests.join([fragment()], "v0.7.2", "x", "2026-11-18", "https://github.com/conrader/swarmhub/releases/download/v0.7.1/")["base"][-7:], "v0.7.1/")

    def test_odd_inputs_are_refused(self):
        for fragments, tag in [([], "v0.7.1"), ([fragment(), fragment(version="0.2.2")], "v0.7.1"), ([fragment(), fragment(api=2)], "v0.7.1"),
                               ([fragment(), fragment()], "v0.7.1"), ([fragment(name="../x")], "v0.7.1"), ([fragment(name=".hidden")], "v0.7.1"),
                               ([fragment()], "0.7.1"), ([fragment()], "v0.7")]:
            with self.subTest(tag=tag, count=len(fragments)), self.assertRaises(ValueError):
                manifests.join(fragments, tag, "x", "2026-11-17")
        with self.assertRaises(ValueError):
            manifests.join([fragment()], "v0.7.1", "x", "2026-11-17", "https://example.com/no-slash")

    def test_a_release_carries_linux_and_both_kinds_of_mac(self):
        targets = ["x86_64-macos", "x86_64-linux", "aarch64-macos"]
        made = manifests.join([fragment(target) for target in targets], "v0.8.0", "Runs on this Mac.", "2026-11-17")
        self.assertEqual([asset["target"] for asset in made["assets"]], ["aarch64-macos", "x86_64-linux", "x86_64-macos"])
        self.assertEqual([asset["name"] for asset in made["assets"]], [f"swarmhub-herdr-0.2.1-{target}" for target in sorted(targets)])
        with self.assertRaisesRegex(ValueError, "same kind of machine"):
            manifests.join([fragment(target) for target in targets] + [fragment("x86_64-macos", name="swarmhub-herdr-0.2.1-x86_64-macos-again")],
                           "v0.8.0", "x", "2026-11-17")

    def test_a_header_says_which_kind_of_machine_a_program_is_for(self):
        for target, header in HEADERS.items():
            self.assertEqual(manifests.built_for(header + bytes(64)), target)
        for other in (b"", b"#!/bin/sh\n", bytes.fromhex("cafebabe00000002"), bytes.fromhex("cffaedfe12000001"), b"\x7fELF\x01\x01\x01" + bytes(13)):
            self.assertIsNone(manifests.built_for(other))

    def test_a_program_this_machine_cannot_run_is_described_from_the_build_it_can(self):
        # A header of the other system is certain not to run here, whichever machine runs the test.
        system = "linux" if sys.platform == "darwin" else "macos"
        with tempfile.TemporaryDirectory() as folder:
            native, other = program(folder, f"aarch64-{system}", api=2), foreign(folder, f"x86_64-{system}")
            said = io.StringIO()
            with contextlib.redirect_stderr(said), contextlib.redirect_stdout(io.StringIO()):
                manifests.main(["asset", str(other), "--target", f"x86_64-{system}", "--like", str(native)])
            self.assertIn("cannot run on this machine", said.getvalue())
            made = json.loads((Path(folder) / (other.name + ".asset.json")).read_text())
            self.assertEqual(made, {"product": "swarmhub-herdr", "version": "0.2.1", "api": 2, "api_min": 1,
                                    "asset": {"target": f"x86_64-{system}", "name": other.name, "size": other.stat().st_size,
                                              "sha256": hashlib.sha256(other.read_bytes()).hexdigest()}})
            # The two join into one manifest with the native build's own fragment.
            joined = manifests.join([manifests.describe(native), made], "v0.8.0", "x", "2026-11-17")
            self.assertEqual([asset["target"] for asset in joined["assets"]], [f"aarch64-{system}", f"x86_64-{system}"])

    def test_a_program_that_does_run_must_agree_with_the_build_it_is_described_from(self):
        with tempfile.TemporaryDirectory() as folder:
            native, other = program(folder, "aarch64-macos"), foreign(folder, "x86_64-macos")
            real = manifests.report

            def answers(own):
                def asked(path):
                    if path != other:
                        return real(path)
                    if isinstance(own, Exception):
                        raise own
                    return own
                return mock.patch.object(manifests, "report", asked)
            with answers({"version": "0.2.1", "api": 1, "api_min": 1, "target": "x86_64-macos", "updates": True}), contextlib.redirect_stderr(io.StringIO()) as said:
                self.assertEqual(manifests.describe(other, "x86_64-macos", native)["asset"]["target"], "x86_64-macos")
            self.assertIn("runs on this machine", said.getvalue())
            for own in ({"version": "0.2.0", "api": 1, "api_min": 1, "target": "x86_64-macos"}, {"version": "0.2.1", "api": 2, "api_min": 1, "target": "x86_64-macos"},
                        {"version": "0.2.1", "api": 1, "api_min": 1, "target": "aarch64-macos"}):
                with self.subTest(own=own), answers(own), self.assertRaises(ValueError):
                    manifests.describe(other, "x86_64-macos", native)
            # Only "this machine cannot run it" is passed over; any other failure to start it is an error.
            with answers(PermissionError(errno.EACCES, "Permission denied")), self.assertRaises(PermissionError):
                manifests.describe(other, "x86_64-macos", native)

    def test_a_program_is_not_described_as_something_its_file_is_not(self):
        with tempfile.TemporaryDirectory() as folder:
            native, other = program(folder, "aarch64-macos"), foreign(folder, "x86_64-macos")
            for path, target, like in [(other, "aarch64-macos", native),                     # the native build's own kind
                                       (other, "x86_64-linux", native),                      # another system
                                       (foreign(folder, "aarch64-linux"), "x86_64-macos", native),   # a file for another machine
                                       (program(folder, "riscv64-macos"), "x86_64-macos", native)]:  # not a program file at all
                with self.subTest(path=path.name, target=target), self.assertRaises(ValueError):
                    manifests.describe(path, target, like)
            for arguments in (["asset", str(other), "--target", "x86_64-macos"], ["asset", str(other), "--like", str(native)]):
                with self.subTest(arguments=arguments[2:3]), contextlib.redirect_stderr(io.StringIO()) as said, self.assertRaises(SystemExit) as stopped:
                    manifests.main(arguments)
                self.assertEqual(stopped.exception.code, 1)
                self.assertIn("go together", said.getvalue())
            self.assertFalse((Path(folder) / (other.name + ".asset.json")).exists())


if __name__ == "__main__":
    unittest.main()
