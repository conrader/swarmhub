"""P0d: the box renders skills byte for byte as SkillLibrary.render (Resources/Updater/swarmhub_update/render.py).

Every golden in Tests/Fixtures/release-bundles/renders/ (written by Tests/AgentAppTests/RenderGoldenTests.swift on
the Mac) must equal the Python render of today's Resources/ for the same skill, profile and coding order, and the
folder must hold exactly the expected set. While the folder carries a PROVISIONAL marker the goldens came from this
port, not from Swift; `python3 Tests/Updater/test_render.py --write-provisional` rewrites them that way (and refuses
when the marker is absent). `--refresh-versions` permits only increasing version metadata in Swift-final goldens;
it refuses any body, reference, file-set or other header change before writing any file.

    python3 -m unittest discover -s Tests/Updater
"""

import ast
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources/Updater"))

from swarmhub_update import render  # noqa: E402

RESOURCES = ROOT / "Resources"
RENDERS = ROOT / "Tests/Fixtures/release-bundles/renders"
HERMES = ROOT / "Tests/Fixtures/hermes_v0.21.7_server.py"
SKILL_NAMES = ["swarmhub-coding", "swarmhub-feedback", "swarmhub-manager", "swarmhub-messages"]
# Same lists as RenderGoldenTests.swift.
PROFILES = ["default", "grok-jarvis", "coder_2"]
ANY_ORDER = "any-order"
NOT_GOLDENS = {"README.md", "PROVISIONAL"}


def load_resources(resources=RESOURCES):
    references = render.load_manager_references(str(resources / "BotManager"))
    folder = str(resources / "Skills")
    skills = [render.load_skill(folder, name, references) for name in sorted(os.listdir(folder))]
    manager = (resources / "BotManager/manager-hermes.md").read_bytes().decode("utf-8")
    return [s for s in skills if s is not None], manager


def order_slug(order):
    return order.replace(",", "-")


def expected_renders(resources=RESOURCES):
    """Golden path -> bytes, laid out as RenderGoldenTests.swift writes them. A skill without `{{CODING_ORDER}}` is
    stored once (`any-order`) and every coding order must render to it."""
    skills, manager = load_resources(resources)
    renders = {}
    for skill in skills:
        for profile in PROFILES:
            for order in render.CODING_ORDERS:
                text = render.render_skill(skill, profile, manager, order)
                if text is None:
                    raise AssertionError("%s did not render" % skill.name)
                slug = order_slug(render.variant(skill, order) or ANY_ORDER)
                path = "%s/%s/%s/SKILL.md" % (skill.name, profile, slug)
                if renders.get(path, text.encode("utf-8")) != text.encode("utf-8"):
                    raise AssertionError("%s differs between coding orders" % path)
                renders[path] = text.encode("utf-8")
            for file in skill.files:
                if file.path.startswith("references/"):
                    rendered = render.render_file(file, profile)
                    renders["%s/%s/files/%s" % (skill.name, profile, file.path)] = rendered.content.encode("utf-8")
    return renders


def goldens_on_disk(folder=RENDERS):
    found = {}
    for directory, _, names in os.walk(folder):
        for name in names:
            full = Path(directory) / name
            path = full.relative_to(folder).as_posix()
            if path not in NOT_GOLDENS:
                found[path] = full.read_bytes()
    return found


def tree_digest(root):
    digest = {}
    for directory, _, names in os.walk(root):
        for name in names:
            full = Path(directory) / name
            digest[full.relative_to(root).as_posix()] = (hashlib.sha256(full.read_bytes()).hexdigest(),
                                                          full.stat().st_mode, full.stat().st_mtime_ns)
    return digest


def skill(template, name="swarmhub-test", version="1.0.0", files=()):
    return render.Skill(name, version, template, tuple(files))


class GoldenTests(unittest.TestCase):
    def test_every_golden_is_byte_identical(self):
        expected, disk = expected_renders(), goldens_on_disk()
        self.assertEqual(sorted(set(expected) - set(disk)), [], "goldens missing")
        self.assertEqual(sorted(set(disk) - set(expected)), [], "stale goldens")
        for path in sorted(expected):
            self.assertEqual(disk[path], expected[path], path)
        self.assertEqual(len(expected), 36)  # 3 profiles x (5 coding + 3 other SKILL.md + 4 references)

    def test_all_four_skills_load_and_render(self):
        skills, manager = load_resources()
        self.assertEqual([s.name for s in skills], SKILL_NAMES, "a skill folder with a non-UTF-8 file (e.g. a stray "
                         "__pycache__ from a test run) is skipped, as the app skips it; delete it and rerun")
        for s in skills:
            for profile in PROFILES:
                for order in render.CODING_ORDERS:
                    text = render.render_skill(s, profile, manager, order)
                    self.assertNotIn("{{", text, (s.name, profile, order))
                    fields = render.frontmatter(text)
                    self.assertEqual((fields["name"], fields["version"]), (s.name, s.version))
                    self.assertIn("Installed by SwarmHub, v%s." % s.version, fields["description"])
        coding = next(s for s in skills if s.name == "swarmhub-coding")
        for order in render.CODING_ORDERS:
            self.assertIn("--order %s" % order, render.render_skill(coding, "coder_2", manager, order))

    def test_manager_skill_carries_core_text_for_profile(self):
        skills, manager = load_resources()
        mgr = next(s for s in skills if s.name == render.MANAGER_SKILL)
        self.assertEqual([f.path for f in mgr.files], ["references/%s.md" % r for r in
                                                       ("accounts", "box", "capacity", "models")])
        for profile in PROFILES:
            text = render.render_skill(mgr, profile, manager)
            core = render.filled(manager, profile).strip(render.SWIFT_WHITESPACES_AND_NEWLINES)
            self.assertIn(core + "\n\nWhen asked to list every bot", text)
            self.assertIn("You are the profile `%s`" % profile, text)
        self.assertIsNone(render.render_skill(mgr, "default", None), "no manager text, no skill")


class SwiftSemanticsTests(unittest.TestCase):
    def test_version_parses_like_skill_version(self):
        cases = {"1.2.3": "1.2.3", "01.002.3": "1.2.3", " 1.2.3\t": "1.2.3", "　1.2.3": "1.2.3",
                 "1.2": None, "1.2.3.4": None, "1..3": None, "1.2.3\n": None, "+1.2.3": None, "1.2.-3": None,
                 "١.2.3": None, "1.2.3́": None, "1.2.%d" % 2 ** 63: None, "1.2.%d" % (2 ** 63 - 1):
                 "1.2.%d" % (2 ** 63 - 1), "": None, None: None}
        for text, want in cases.items():
            self.assertEqual(render.parse_version(text), want, repr(text))

    def test_newline_suffix_is_character_based(self):
        self.assertEqual(render.render_skill(skill("a"), "x", None), "a\n")
        self.assertEqual(render.render_skill(skill("a\n"), "x", None), "a\n")
        self.assertEqual(render.render_skill(skill("a\r\n"), "x", None), "a\r\n\n", "\\r\\n is one Character")
        self.assertEqual(render.render_skill(skill("a\n\r"), "x", None), "a\n\r\n")
        self.assertEqual(render.render_skill(skill(""), "x", None), "\n")

    def test_replacement_order_and_scope(self):
        template = "v{{VERSION}} {{MANAGER_TEXT}} {{BOT}} {{SKILL_DIR}} {{CODING_ORDER}}"
        manager = "  　\n{{MANAGER}} {{MANAGER_ENV}} {{VERSION}} {{BOT}} {{CODING_ORDER}}\x1c \n "
        out = render.render_skill(skill(template, version="2.0.1"), "coder_2", manager, "codex")
        self.assertEqual(out, "v2.0.1 coder_2 ~/.hermes/profiles/coder_2/.env {{VERSION}} coder_2 codex\x1c coder_2 "
                              "~/.hermes/profiles/coder_2/skills/swarmhub/swarmhub-test codex\n")
        default = render.render_skill(skill("{{SKILL_DIR}} {{MANAGER_TEXT}}"), "default", "{{MANAGER_ENV}}")
        self.assertEqual(default, "~/.hermes/skills/swarmhub/swarmhub-test ~/.hermes/.env\n")
        self.assertEqual(render.render_skill(skill("{{CODING_ORDER}}"), "x", None), "claude,codex,hermes\n")
        self.assertEqual(render.render_skill(skill("{{VERSION}} plain"), "x", None), "1.0.0 plain\n")

    def test_inserted_manager_text_can_complete_a_placeholder_like_swift(self):
        out = render.render_skill(skill("{{CODING_{{MANAGER_TEXT}}"), "x", "ORDER}}", "hermes")
        self.assertEqual(out, "hermes\n", "sequential replacement, as replacingOccurrences does")

    def test_file_render_fills_references_only(self):
        ref = render.SkillFile("references/box.md", "{{MANAGER}} {{MANAGER_ENV}} {{BOT}}")
        script = render.SkillFile("scripts/x", "{{MANAGER}} {{BOT}}")
        self.assertEqual(render.render_file(ref, "default"), ("references/box.md", "default ~/.hermes/.env {{BOT}}"))
        self.assertIs(render.render_file(script, "default"), script)
        skills, _ = load_resources()
        for s in skills:
            for f in s.files:
                if not f.path.startswith("references/"):
                    self.assertIs(render.render_file(f, "coder_2"), f, f.path)

    def test_install_files_end_in_newline_the_swift_way(self):
        s = skill("{{BOT}}", files=[render.SkillFile("references/a.md", "{{MANAGER}}"),
                                    render.SkillFile("scripts/b", "x\r\n"), render.SkillFile("scripts/c", "y\n")])
        self.assertEqual(render.install_files(s, "p", None),
                         [("SKILL.md", "p\n"), ("references/a.md", "p\n"), ("scripts/b", "x\r\n\n"), ("scripts/c", "y\n")])
        self.assertIsNone(render.install_files(skill("{{MANAGER_TEXT}}"), "p", None))

    def test_bad_arguments_fail_closed(self):
        for profile in ["", "a b", "a/b", "x" * 65, "é", "a\n", "../x", None]:
            with self.assertRaises(render.RenderError, msg=repr(profile)):
                render.render_skill(skill("t"), profile, None)
        for order in ["claude,hermes", "", "Claude", None]:
            with self.assertRaises(render.RenderError):
                render.render_skill(skill("t"), "x", None, order)
        for version in ["01.0.0", "1.0", None]:
            with self.assertRaises(render.RenderError):
                render.render_skill(skill("t", version=version), "x", None)
        render.render_skill(skill("t"), "x" * 64, None)

    def test_grapheme_joined_placeholders_fail_closed(self):
        for template in ["{{BOT}}́", "{{VERSION}}‍", "‍{{SKILL_DIR}}", "{{CODING_ORDER}}\U0001F3FB",
                         "{{MANAGER_TEXT}}⃝"]:
            with self.assertRaises(render.RenderError, msg=repr(template)):
                render.render_skill(skill(template), "x", "m")
        with self.assertRaises(render.RenderError):
            render.render_skill(skill("{{MANAGER_TEXT}}"), "x", "{{MANAGER}}́")
        self.assertEqual(render.render_skill(skill("é{{BOT}}é"), "x", None), "éxé\n")

    def test_frontmatter_matches_swift(self):
        text = '---\nname: "a"\nversion:  1.2.3 \n  nested: z\nk:v:w\nnocolon\n\tt: q\n---\nname: body\n'
        self.assertEqual(render.frontmatter(text), {"name": "a", "version": "1.2.3", "k": "v:w", "\tt": "q"})
        self.assertEqual(render.frontmatter("---\nname: a\n"), {})
        self.assertEqual(render.frontmatter("--- \nname: a\n---\n"), {})
        for bad in ["---\nname: a\r\nversion: 1\n---\n", "---\nname: á\n---\n", "---\n﻿name: a\n---\n"]:
            with self.assertRaises(render.RenderError):
                render.frontmatter(bad)


class LoaderAndHermesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_loader_skips_what_bundled_skips(self):
        folder = self.tmp / "skills"
        (folder / "good/scripts").mkdir(parents=True)
        (folder / "good/SKILL.md").write_text("---\nname: good\nversion: 1.0.0\n---\n")
        (folder / "good/scripts/run").write_text("x")
        (folder / "good/.hidden").write_text("x")
        self.assertEqual(render.load_skill(str(folder), "good"),
                         ("good", "1.0.0", "---\nname: good\nversion: 1.0.0\n---\n", (("scripts/run", "x"),)))
        for name, body in [("misnamed", "name: other\nversion: 1.0.0"), ("noversion", "name: noversion"),
                           ("badver", "name: badver\nversion: 1.0")]:
            (folder / name).mkdir()
            (folder / name / "SKILL.md").write_text("---\n%s\n---\n" % body)
            self.assertIsNone(render.load_skill(str(folder), name), name)
        (folder / "good/scripts/bad name").write_text("x")
        self.assertIsNone(render.load_skill(str(folder), "good"), "unsafe path")
        (folder / "good/scripts/bad name").unlink()
        (folder / "good/scripts/bin").write_bytes(b"\xff")
        self.assertIsNone(render.load_skill(str(folder), "good"), "not UTF-8")
        (folder / "good/scripts/bin").unlink()
        os.symlink("/etc/hostname", str(folder / "good/scripts/link"))
        self.assertIsNone(render.load_skill(str(folder), "good"), "symlink")
        (folder / "good/scripts/link").unlink()
        shutil.copytree(str(RESOURCES / "Skills/swarmhub-manager"), str(folder / "swarmhub-manager"))
        self.assertIsNone(render.load_skill(str(folder), "swarmhub-manager"), "manager needs its references")

    def test_rendering_leaves_hermes_files_byte_identical(self):
        home = self.tmp / "home"
        hermes = home / ".hermes"
        (hermes / "hermes-agent").mkdir(parents=True)
        shutil.copy2(str(HERMES), str(hermes / "hermes-agent/server.py"))
        (hermes / "config.yaml").write_text("model:\n  default: x\n")
        (hermes / ".env").write_text("API_SERVER_KEY=test\n")
        (hermes / "profiles/coder_2").mkdir(parents=True)
        (hermes / "profiles/coder_2/config.yaml").write_text("model:\n  default: y\n")
        staged = self.tmp / "staged"
        shutil.copytree(str(RESOURCES / "Skills"), str(staged / "Skills"))
        shutil.copytree(str(RESOURCES / "BotManager"), str(staged / "BotManager"))
        before, staged_before = tree_digest(home), tree_digest(staged)
        old_cwd, old_home = os.getcwd(), os.environ.get("HOME")
        os.chdir(str(hermes))
        os.environ["HOME"] = str(home)
        try:
            renders = expected_renders(staged)
            skills, manager = load_resources(staged)
            for s in skills:
                for profile in PROFILES:
                    for f in render.install_files(s, profile, manager):
                        self.assertTrue(render.is_safe_relative_path(f.path))
                    self.assertRegex(render.install_path(s.name, profile), r"^~/\.hermes/(profiles/[^/]+/)?skills/swarmhub/")
        finally:
            os.chdir(old_cwd)
            if old_home is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = old_home
        self.assertEqual(renders, expected_renders())
        self.assertEqual(tree_digest(home), before, "Hermes files must stay byte-identical")
        self.assertEqual(tree_digest(staged), staged_before, "the renderer must not touch its inputs")
        self.assertEqual(HERMES.read_bytes(), (hermes / "hermes-agent/server.py").read_bytes())

    def test_renderer_has_no_write_or_process_calls(self):
        tree = ast.parse((ROOT / "Resources/Updater/swarmhub_update/render.py").read_text())
        imports = {a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
        imports |= {n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
        self.assertEqual(imports, {"collections", "os", "re", "stat", "unicodedata"})
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")
            owner = func.value.id if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) else ""
            if owner == "os":
                self.assertIn(name, {"walk", "lstat"}, "os.%s" % name)
            builtin = isinstance(func, ast.Name) and name in {"eval", "exec", "compile", "__import__", "getattr", "setattr"}
            self.assertFalse(builtin or name in {"write", "write_text", "write_bytes", "chmod"}, name)
            if name == "open":
                mode = node.args[1] if len(node.args) == 2 and not node.keywords else None
                self.assertTrue(isinstance(mode, ast.Constant) and mode.value == "rb", "open() is read-only")

def version_neutral(data):
    """Strip only the two rendered version fields from a complete golden, preserving every other byte."""
    fields = render.frontmatter(data.decode("utf-8"))
    version = fields.get("version", "")
    if render.parse_version(version) != version or not version:
        raise ValueError("invalid golden version")
    header, sep, body = data[4:].partition(b"\n---\n")
    line = b"\nversion: " + version.encode() + b"\n"
    advertised = b"Installed by SwarmHub, v" + version.encode() + b"."
    if not data.startswith(b"---\n") or not sep or header.count(line) != 1 or header.count(advertised) != 1:
        raise ValueError("missing or ambiguous version metadata")
    header = header.replace(line, b"\nversion: {{VERSION}}\n", 1).replace(advertised, b"Installed by SwarmHub, v{{VERSION}}.", 1)
    return version, b"---\n" + header + sep + body


def refresh_versions(renders=None, folder=RENDERS):
    """Regenerate metadata-only bumps without replacing Swift's body goldens or their provenance."""
    renders = expected_renders() if renders is None else renders
    disk = goldens_on_disk(folder)
    if (folder / "PROVISIONAL").exists() or set(renders) != set(disk):
        raise ValueError("requires the same complete set of Swift-final goldens")
    changed = {}
    for path, data in renders.items():
        if data == disk[path]:
            continue
        if not path.endswith("/SKILL.md"):
            raise ValueError("not a version-only change: " + path)
        old, old_body = version_neutral(disk[path])
        new, new_body = version_neutral(data)
        if old_body != new_body or tuple(map(int, new.split("."))) <= tuple(map(int, old.split("."))):
            raise ValueError("not a version-only increase: " + path)
        changed[path] = data
    # Validate the entire set before writing, using generated bytes only.
    for path, data in changed.items():
        (folder / path).write_bytes(data)
    print("refreshed %d version-only goldens; Swift body bytes preserved" % len(changed))


class VersionRefreshTests(unittest.TestCase):
    def test_version_increase_regenerates_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            path = "test/default/any-order/SKILL.md"
            golden = folder / path
            golden.parent.mkdir(parents=True)
            old = b"---\nname: test\nversion: 1.4.5\ndescription: Installed by SwarmHub, v1.4.5.\n---\nBody 1.4.5\n"
            golden.write_bytes(old)
            new = old.replace(b"version: 1.4.5", b"version: 1.4.6").replace(b"v1.4.5.", b"v1.4.6.")
            refresh_versions({path: new}, folder)
            self.assertEqual(golden.read_bytes(), new)
            self.assertFalse((folder / "PROVISIONAL").exists())

    def test_other_changes_refuse_before_any_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            old = b"---\nname: test\nversion: 1.4.5\ndescription: Installed by SwarmHub, v1.4.5.\n---\nBody\n"
            new = old.replace(b"1.4.5", b"1.4.6")
            original = {"a/SKILL.md": old, "b/SKILL.md": old, "b/files/reference.md": b"Reference\n"}
            for path, data in original.items():
                (folder / path).parent.mkdir(parents=True, exist_ok=True)
                (folder / path).write_bytes(data)
            cases = [
                {"b/SKILL.md": new + b"Changed body\n"},
                {"b/SKILL.md": new.replace(b"name: test", b"name: other")},
                {"b/SKILL.md": old.replace(b"1.4.5", b"1.4.4")},
                {"b/SKILL.md": old.replace(b"Body", b"Changed")},
                {"b/files/reference.md": b"Changed reference\n"},
                {"extra/SKILL.md": new},
            ]
            for edits in cases:
                with self.subTest(edits=edits):
                    with self.assertRaises(ValueError):
                        refresh_versions(dict(original, **{"a/SKILL.md": new}, **edits), folder)
                    self.assertEqual(goldens_on_disk(folder), original)
            (folder / "PROVISIONAL").write_text("Python-generated")
            with self.assertRaises(ValueError):
                refresh_versions(dict(original, **{"a/SKILL.md": new}), folder)
            self.assertEqual(goldens_on_disk(folder), original)


def write_provisional():
    if RENDERS.exists() and goldens_on_disk() and not (RENDERS / "PROVISIONAL").exists():
        sys.exit("refusing: goldens are Swift-final (no PROVISIONAL marker); regenerate them on the Mac instead")
    renders = expected_renders()
    for entry in RENDERS.iterdir() if RENDERS.exists() else []:
        if entry.name != "README.md":
            shutil.rmtree(str(entry)) if entry.is_dir() else entry.unlink()
    for path, data in renders.items():
        (RENDERS / path).parent.mkdir(parents=True, exist_ok=True)
        (RENDERS / path).write_bytes(data)
    (RENDERS / "PROVISIONAL").write_text("Written by Tests/Updater/test_render.py --write-provisional (Python port), "
                                         "not by Swift. See README.md.\n")
    print("wrote %d provisional goldens to %s" % (len(renders), RENDERS))


if __name__ == "__main__":
    if sys.argv[1:] == ["--write-provisional"]:
        write_provisional()
    elif sys.argv[1:] == ["--refresh-versions"]:
        try:
            refresh_versions()
        except (ValueError, render.RenderError) as error:
            sys.exit("refusing: %s; regenerate with Swift on the Mac" % error)
    else:
        unittest.main()
