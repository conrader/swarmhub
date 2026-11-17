import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("workspace_manifest", ROOT / "scripts/workspace-manifest.py")
manifests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifests)


def fragment(target="x86_64-linux", version="0.2.1", name=None, api=1):
    return {"product": "swarmhub-herdr", "version": version, "api": api, "api_min": 1,
            "asset": {"target": target, "name": name or f"swarmhub-herdr-{version}-{target}", "size": 3, "sha256": "ab" * 32}}


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


if __name__ == "__main__":
    unittest.main()
