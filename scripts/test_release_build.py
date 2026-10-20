"""P1a: build_bundle.py classes components, declares requires_component and rebuilds byte-identically.

    python3 scripts/test_release_build.py
"""

import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))

import build_bundle  # noqa: E402
from build_bundle import BuildError  # noqa: E402

CREATED = "2026-10-20T12:00:00Z"
DATA_EXTENSIONS = {"skill": {".md"}, "config": {".json", ".md", ".txt"}, "ui": {".json"}}


def build_real(version=1, previous=None):
    return build_bundle.build(version=version, label=f"2026.10.{version}", created=CREATED, previous=previous)


def members(blob):
    with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
        return {m.name.rstrip("/"): m for m in archive.getmembers()}


def needs_code(kind, blob):
    """The SCHEMAS.md §7 content rule, re-derived here from the archive with tarfile (independent of the tool)."""
    for name, member in members(blob).items():
        if member.isfile() and (member.mode == 0o755 or Path(name).suffix not in DATA_EXTENSIONS[kind]):
            return True
    return False


class Tree:
    """A temporary repository root plus a layout file, for synthetic bundles."""

    def __init__(self, test):
        self.dir = Path(tempfile.mkdtemp(prefix="p1a-build-"))
        test.addCleanup(subprocess.run, ["rm", "-rf", str(self.dir)])
        self.layout = {"schema": "swarmhub/bundle-layout/1", "requires": {"updater": ">=1.0"}, "components": []}

    def file(self, rel, text, mode=0o644):
        path = self.dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
        os.chmod(path, mode)
        return path

    def skill(self, name, version="1.0.0", extra=None, **entry):
        self.file(f"src/{name}/SKILL.md", f"---\nname: {name}\nversion: {version}\n---\nText.\n")
        for rel, (text, mode) in (extra or {}).items():
            self.file(f"src/{name}/{rel}", text, mode)
        return self.component("skill", name, **entry)

    def component(self, kind, name, version=None, targets=("box",), **entry):
        existing = [c for c in self.layout["components"] if c["name"] == name]
        item = existing[0] if existing else {"kind": kind, "name": name, "targets": list(targets),
                                             "sources": [{"from": f"src/{name}"}]}
        if version and kind != "skill":
            item["version"] = version
        item.update(entry)
        if not existing:
            self.layout["components"].append(item)
        return item

    def build(self, version=1, previous=None):
        layout = self.dir / "layout.json"
        layout.write_text(json.dumps(self.layout), encoding="utf-8")
        return build_bundle.build(version=version, label=f"t.{version}", created=CREATED, previous=previous,
                                  layout_path=layout, root=self.dir)

    def by_name(self, body):
        return {c["name"]: c for c in body["components"]}


class RealResourcesTests(unittest.TestCase):
    """The bundle built from today's Resources/Skills, Resources/BotManager and the policy defaults."""

    @classmethod
    def setUpClass(cls):
        cls.body, cls.blobs = build_real()
        cls.components = {c["name"]: c for c in cls.body["components"]}

    def test_every_component_is_classed_by_kind_and_content(self):
        expected = {"swarmhub-coding": "code", "swarmhub-feedback": "code", "swarmhub-messages": "code",
                    "swarmhub-manager": "data", "manager-prompts": "data", "policy": "data"}
        self.assertEqual({n: c["class"] for n, c in self.components.items()}, expected)
        for component in self.body["components"]:
            blob = self.blobs[component["sha256"]]
            code = component["kind"] == "tool" or needs_code(component["kind"], blob)
            self.assertEqual(component["class"], "code" if code else "data", component["name"])
            if component["kind"] == "skill":
                has_script = any(m.isfile() and n != "SKILL.md" and not n.startswith("references/")
                                 for n, m in members(blob).items())
                self.assertEqual(component["class"] == "code", has_script, component["name"])

    def test_code_bearing_is_set_because_a_code_component_is_present(self):
        self.assertTrue(self.body["code_bearing"])
        self.assertEqual(self.body["code_bearing"], any(c["class"] == "code" for c in self.body["components"]))

    def test_skill_archives_hold_exactly_the_tracked_skill_files(self):
        try:
            listing = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-s", "Resources/Skills", "Resources/BotManager"],
                                     capture_output=True, text=True, check=True).stdout.splitlines()
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("not a git checkout")
        tracked = {}
        for line in listing:
            mode, _, _, path = line.split(None, 3)
            tracked[path] = 0o755 if mode == "100755" else 0o644
        for name in ("swarmhub-coding", "swarmhub-feedback", "swarmhub-messages"):
            files = {n: m.mode for n, m in members(self.blobs[self.components[name]["sha256"]]).items() if m.isfile()}
            prefix = f"Resources/Skills/{name}/"
            self.assertEqual(files, {p[len(prefix):]: mode for p, mode in tracked.items() if p.startswith(prefix)})
        manager = {n for n, m in members(self.blobs[self.components["swarmhub-manager"]["sha256"]]).items() if m.isfile()}
        recipes = {"references/" + p.rsplit("/", 1)[1] for p in tracked if p.startswith("Resources/BotManager/recipes/")}
        self.assertEqual(manager, {"SKILL.md"} | recipes)

    def test_versions_targets_and_dependencies(self):
        for name in ("swarmhub-coding", "swarmhub-feedback", "swarmhub-manager", "swarmhub-messages"):
            text = (ROOT / f"Resources/Skills/{name}/SKILL.md").read_text(encoding="utf-8")
            self.assertEqual(self.components[name]["version"], re.search(r"^version: (\S+)$", text, re.M).group(1))
            self.assertEqual(self.components[name]["targets"], ["box"])
        self.assertEqual(self.components["manager-prompts"]["targets"], ["box", "mac"])
        self.assertEqual(self.components["policy"]["targets"], ["mac", "ios"])
        deps = {d["name"]: d["min_version"] for d in self.components["swarmhub-manager"]["requires_component"]}
        # The accounts recipe runs swarmhub-claude-login, shipped by swarmhub-coding (new data needing new code).
        self.assertEqual(deps["swarmhub-coding"], self.components["swarmhub-coding"]["version"])
        self.assertIn("manager-prompts", deps)  # SKILL.md renders {{MANAGER_TEXT}} from manager-hermes.md

    def test_policy_defaults_match_the_swift_sources(self):
        policy = json.loads((ROOT / "scripts/release/policy_defaults.json").read_text(encoding="utf-8"))
        coding = (ROOT / "Sources/AgentApp/Models/CodingOrder.swift").read_text(encoding="utf-8")
        standard = re.search(r"static let standard = CodingOrder\.(\w+)", coding).group(1)
        self.assertEqual(policy["codingOrder"], re.search(rf'case {standard} = "([^"]+)"', coding).group(1))
        team = (ROOT / "Packages/SwarmHubCoordination/Sources/SwarmHubCoordination/TeamPolicy.swift").read_text("utf-8")
        limits = re.search(r"struct TeamLimits[^{]*\{(.*?)public init", team, re.S).group(1)
        swift = {k: int(v) for k, v in re.findall(r"public var (\w+)(?:: \w+)? = (\d+)", limits)}
        self.assertEqual(policy["teamLimits"], swift)
        actions = re.search(r"public var actions: Set<String> = \[([^\]]*)\]", team).group(1)
        self.assertEqual(policy["teamActions"], sorted(re.findall(r'"(\w+)"', actions)))
        model = (ROOT / "Sources/AgentApp/Models/ModelPolicy.swift").read_text(encoding="utf-8")
        defaults = re.search(r"struct ModelDefaults[^{]*\{(.*?)var isEmpty", model, re.S).group(1)
        self.assertNotIn("=", re.sub(r"///.*", "", defaults))  # every ModelDefaults member is unset by default
        self.assertEqual(policy["modelDefaults"], {})
        blob = self.blobs[self.components["policy"]["sha256"]]
        with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
            self.assertEqual(json.load(archive.extractfile("policy.json")), policy)


class ReproducibleTests(unittest.TestCase):
    def test_rebuild_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as temp:
            outs = []
            for run in ("a", "b"):
                body, blobs = build_real()
                build_bundle.write_build(Path(temp) / run, body, blobs)
                outs.append({str(p.relative_to(Path(temp) / run)): p.read_bytes()
                             for p in sorted((Path(temp) / run).rglob("*")) if p.is_file()})
            self.assertEqual(outs[0], outs[1])
            self.assertEqual(len(outs[0]), 7)  # six blobs and the manifest

    def test_mtimes_owners_and_non_exec_mode_bits_do_not_change_bytes(self):
        tree = Tree(self)
        tree.skill("alpha", extra={"scripts/run.py": ("print(1)\n", 0o755), "notes.md": ("n\n", 0o644)})
        first = tree.build()
        os.utime(tree.dir / "src/alpha/notes.md", (1, 1))
        os.chmod(tree.dir / "src/alpha/notes.md", 0o664)
        os.chmod(tree.dir / "src/alpha/scripts/run.py", 0o775)
        self.assertEqual(tree.build(), first)

    def test_caches_and_hidden_files_are_left_out_and_symlinks_stop_the_build(self):
        tree = Tree(self)
        tree.skill("alpha", extra={"scripts/__pycache__/x.cpython-312.pyc": (b"\x00\xff", 0o644),
                                   ".DS_Store": (b"\x00", 0o644), "scripts/stale.pyc": (b"\x00", 0o644)})
        body, blobs = tree.build()
        self.assertEqual(set(members(blobs[body["components"][0]["sha256"]])), {"SKILL.md"})
        os.symlink("SKILL.md", tree.dir / "src/alpha/link.md")
        with self.assertRaisesRegex(BuildError, "symlink"):
            tree.build()


class ClassificationTests(unittest.TestCase):
    def test_tool_is_code_even_with_only_markdown(self):
        tree = Tree(self)
        tree.file("src/tool-a/README.md", "only text\n")
        tree.component("tool", "tool-a", version="1.0.0")
        body, _ = tree.build()
        self.assertEqual(tree.by_name(body)["tool-a"]["class"], "code")
        self.assertTrue(body["code_bearing"])

    def test_skill_is_code_with_a_script_an_exec_bit_or_a_non_markdown_file(self):
        tree = Tree(self)
        tree.skill("plain", extra={"references/a.md": ("a\n", 0o644)})
        tree.skill("script", extra={"scripts/run.py": ("print(1)\n", 0o644)})
        tree.skill("exec-md", extra={"run.md": ("#!/bin/sh\n", 0o755)})
        tree.skill("json-file", extra={"data.json": ("{}\n", 0o644)})
        body, _ = tree.build()
        classes = {n: c["class"] for n, c in tree.by_name(body).items()}
        self.assertEqual(classes, {"plain": "data", "script": "code", "exec-md": "code", "json-file": "code"})

    def test_code_bearing_is_false_when_every_component_is_data(self):
        tree = Tree(self)
        tree.skill("plain")
        tree.file("src/prompts/a.md", "p\n")
        tree.file("src/prompts/b.json", "{}\n")
        tree.component("config", "prompts", version="1.0.0", targets=("box", "mac"))
        body, _ = tree.build()
        self.assertFalse(body["code_bearing"])
        tree.skill("script", extra={"scripts/run": ("#!/bin/sh\n", 0o755)})
        self.assertTrue(tree.build()[0]["code_bearing"])

    def test_config_or_ui_holding_code_stops_the_build(self):
        for kind, rel in (("config", "hook.sh"), ("config", "a.md"), ("ui", "card.md")):
            tree = Tree(self)
            tree.file(f"src/c/{rel}", "x\n", 0o755 if rel == "a.md" else 0o644)
            tree.component(kind, "c", version="1.0.0", targets=("mac",))
            with self.assertRaisesRegex(BuildError, "must be data"):
                tree.build()


class RequiresComponentTests(unittest.TestCase):
    def tree(self):
        tree = Tree(self)
        tree.file("src/tools/swarmctl", "#!/bin/sh\necho 1\n", 0o755)
        tree.component("tool", "tools", version="1.0.0")
        tree.skill("guide", uses=["tools"])
        return tree

    def test_baseline_refuses_new_data_using_new_code_until_declared(self):
        tree = self.tree()
        with self.assertRaisesRegex(BuildError, "missing requires_component: guide 1.0.0 uses tools"):
            tree.build()
        tree.component("skill", "guide", requires_component=[{"name": "tools", "min_version": "1.0.0"}])
        body, _ = tree.build()
        self.assertEqual(tree.by_name(body)["guide"]["requires_component"], [{"name": "tools", "min_version": "1.0.0"}])

    def test_changed_data_needs_current_code_but_unchanged_data_keeps_its_minimum(self):
        tree = self.tree()
        tree.component("skill", "guide", requires_component=[{"name": "tools", "min_version": "1.0.0"}])
        v1, _ = tree.build(1)
        tree.file("src/tools/swarmctl", "#!/bin/sh\necho 2\n", 0o755)
        tree.component("tool", "tools", version="1.1.0")
        v2, _ = tree.build(2, previous=v1)  # code alone changed: the data component did not, nothing new to declare
        tree.skill("guide", version="1.1.0", extra={"more.md": ("uses swarmctl 1.1\n", 0o644)})
        tree.component("skill", "guide", requires_component=[{"name": "tools", "min_version": "1.1.0"}])
        v3, _ = tree.build(3, previous=v2)  # data needs 1.1 even if the box has not confirmed bundle 2's code
        tree.file("src/tools/swarmctl", "#!/bin/sh\necho 3\n", 0o755)
        tree.component("tool", "tools", version="1.2.0")
        tree.skill("guide", version="1.2.0")
        with self.assertRaisesRegex(BuildError, "missing requires_component: guide 1.2.0 uses tools 1.2.0"):
            tree.build(4, previous=v3)  # both changed, the old declaration (>= 1.1.0) is too low
        tree.component("skill", "guide", requires_component=[{"name": "tools", "min_version": "1.2.0"}])
        v4, _ = tree.build(4, previous=v3)
        self.assertEqual(tree.by_name(v4)["guide"]["requires_component"][0]["min_version"], "1.2.0")

    def test_new_data_requires_previously_published_code_at_its_needed_version(self):
        tree = self.tree()
        tree.component("skill", "guide", requires_component=[{"name": "tools", "min_version": "1.0.0"}])
        v1, _ = tree.build(1)
        tree.file("src/tools/swarmctl", "#!/bin/sh\necho 2\n", 0o755)
        tree.component("tool", "tools", version="1.1.0")
        v2, _ = tree.build(2, previous=v1)
        tree.skill("guide", version="1.1.0", extra={"more.md": ("needs swarmctl 1.1\n", 0o644)})
        for deps in ([], [{"name": "tools", "min_version": "1.0.0"}]):
            with self.subTest(deps=deps):
                tree.component("skill", "guide", requires_component=deps)
                with self.assertRaisesRegex(BuildError, "missing requires_component: guide 1.1.0 uses tools"):
                    tree.build(3, previous=v2)
        tree.component("skill", "guide", requires_component=[{"name": "tools", "min_version": "1.1.0"}])
        v3, _ = tree.build(3, previous=v2)
        self.assertEqual(tree.by_name(v3)["guide"]["requires_component"],
                         [{"name": "tools", "min_version": "1.1.0"}])

    def test_invalid_declarations_stop_the_build(self):
        tree = self.tree()
        tree.component("skill", "guide", requires_component=[{"name": "tools", "min_version": "2.0.0"}])
        with self.assertRaisesRegex(BuildError, "requires tools >= 2.0.0"):
            tree.build()
        tree.component("skill", "guide", requires_component=[{"name": "nope", "min_version": "1.0.0"}])
        with self.assertRaisesRegex(BuildError, "not another component"):
            tree.build()
        tree.component("skill", "guide", uses=["guide"], requires_component=[])
        with self.assertRaisesRegex(BuildError, "not a code component"):
            tree.build()

    def test_dependency_must_reach_every_target(self):
        tree = Tree(self)
        tree.file("src/prompts/a.md", "p\n")
        tree.component("config", "prompts", version="1.0.0", targets=("mac",))
        tree.skill("guide", requires_component=[{"name": "prompts", "min_version": "1.0.0"}])
        with self.assertRaisesRegex(BuildError, "does not reach every target"):
            tree.build()


class PreviousBundleTests(unittest.TestCase):
    def test_content_change_needs_a_version_bump_and_versions_never_go_down(self):
        tree = Tree(self)
        tree.skill("guide", version="1.1.0")
        v1, _ = tree.build(1)
        tree.file("src/guide/extra.md", "new text\n")
        with self.assertRaisesRegex(BuildError, "changed but kept version 1.1.0"):
            tree.build(2, previous=v1)
        tree.skill("guide", version="1.0.9")
        with self.assertRaisesRegex(BuildError, "lower than 1.1.0"):
            tree.build(2, previous=v1)
        tree.skill("guide", version="1.2.0")
        self.assertEqual(tree.build(2, previous=v1)[0]["components"][0]["version"], "1.2.0")
        with self.assertRaisesRegex(BuildError, "must be above the previous bundle 1"):
            tree.build(1, previous=v1)


class CliTests(unittest.TestCase):
    def test_cli_writes_the_build_and_refuses_a_non_empty_out(self):
        with tempfile.TemporaryDirectory() as temp:
            args = ["--version", "1", "--label", "2026.10.1", "--created", CREATED, "--baseline", "--out", temp + "/b"]
            self.assertEqual(build_bundle.main(args), 0)
            manifest = Path(temp, "b/bundle-1.unsigned.json").read_bytes()
            body = json.loads(manifest)
            for component in body["components"]:
                blob = Path(temp, "b/blobs/sha256", component["sha256"]).read_bytes()
                self.assertEqual(hashlib.sha256(blob).hexdigest(), component["sha256"])
            self.assertEqual(build_bundle.main(args), 1)
            self.assertEqual(build_bundle.main(args[:-3] + ["--repo", temp, "--out", temp + "/c"]), 1)


if __name__ == "__main__":
    unittest.main()
