"""Skill rendering for a box profile, byte for byte as the app does it (CORE-PLAN.md §3.4, phase P0d).

A port of `SkillLibrary.render` (Sources/AgentApp/BotManager/SkillLibrary.swift, both overloads), the helpers it
calls (`BotManagerText.filled`, `installPath`, `skillsRoot`, `envPath`, `CodingOrder.argument`), `SkillVersion`,
`SkillLibrary.frontmatter` and the folder walk of `bundled()`/`extraFiles(in:)`. Swift-rendered goldens in
Tests/Fixtures/release-bundles/renders/ pin the output (Tests/Updater/test_render.py).

Where Swift's String semantics differ from Python's, the port follows Swift:
- the final "ends with a newline" check is Character-based, so text ending in "\\r\\n" (one Character) gets "\\n";
- trimming uses Foundation's `.whitespaces` / `.whitespacesAndNewlines` sets, not `str.strip()`;
- a version parses only as three ASCII digit runs that fit an Int64, after trimming `.whitespaces`.
Inputs whose Swift result would depend on grapheme or canonical-equivalence matching (a placeholder or frontmatter
character joined to a combining mark or format character, a carriage return or byte order mark in frontmatter)
raise RenderError instead of guessing. Pure: nothing here writes a file or starts a process. Stdlib only, 3.8+.
"""

from collections import namedtuple
import os
import re
import stat
import unicodedata

MANAGER_SKILL = "swarmhub-manager"
CATEGORY = "swarmhub"
CODING_ORDERS = ("claude,codex,hermes", "codex,claude,hermes", "claude", "codex", "hermes")
STANDARD_ORDER = CODING_ORDERS[0]
# BotManagerText.Recipe.allCases, in order: the manager skill's references/ files.
RECIPES = ("box", "accounts", "models", "capacity")
PLACEHOLDERS = ("{{VERSION}}", "{{MANAGER_TEXT}}", "{{CODING_ORDER}}", "{{SKILL_DIR}}", "{{BOT}}",
                "{{CONNECTOR_RUNNER}}", "{{MANAGER_ENV}}", "{{MANAGER}}")

# Foundation CharacterSet.whitespaces (general category Zs plus tab) and .whitespacesAndNewlines (plus U+000A-U+000D,
# U+0085, U+2028, U+2029). Spelled out: Python's isspace() also covers U+001C-U+001F, which Swift does not trim.
SWIFT_WHITESPACES = "\t                　"
SWIFT_WHITESPACES_AND_NEWLINES = SWIFT_WHITESPACES + "\n\u000b\u000c\r\u0085  "
INT64_MAX = 2 ** 63 - 1
PROFILE_NAME = re.compile(r"[A-Za-z0-9_-]{1,64}")
SAFE_PART = re.compile(r"[A-Za-z0-9._-]+")

Skill = namedtuple("Skill", "name version template files")  # BundledSkill; version normalised, files sorted
SkillFile = namedtuple("SkillFile", "path content")


class RenderError(ValueError):
    pass


def parse_version(text):
    """`SkillVersion(text).description`: "major.minor.patch" normalised ("01.2.3" -> "1.2.3"), else None."""
    if not isinstance(text, str):
        return None
    parts = text.strip(SWIFT_WHITESPACES).split(".")
    if len(parts) != 3 or not all(p and all("0" <= c <= "9" for c in p) for p in parts):
        return None
    numbers = [int(p) for p in parts]
    return None if any(n > INT64_MAX for n in numbers) else "%d.%d.%d" % tuple(numbers)


def is_valid_profile_name(name):
    """`HermesKeyPaste.isValidProfileName`: 1-64 ASCII letters, digits, `-`, `_`."""
    return isinstance(name, str) and PROFILE_NAME.fullmatch(name) is not None


def is_safe_relative_path(path):
    """`SkillLibrary.isSafeRelativePath`: `/`-separated parts of ASCII letters, digits, `.`, `_`, `-`; none `.`/`..`."""
    return isinstance(path, str) and all(SAFE_PART.fullmatch(p) and p not in (".", "..") for p in path.split("/"))


def skills_root(profile):
    return "~/.hermes/skills" if profile == "default" else "~/.hermes/profiles/%s/skills" % profile


def install_path(skill, profile):
    return "%s/%s/%s" % (skills_root(profile), CATEGORY, skill)


def env_path(profile):
    return "~/.hermes/.env" if profile == "default" else "~/.hermes/profiles/%s/.env" % profile


def _joins_grapheme(char, after):
    """True when `char` could fuse with a neighbouring ASCII character into one Swift Character (approximation that
    errs towards refusing): combining marks, format characters (ZWJ, prepend signs), emoji modifiers."""
    category = unicodedata.category(char)
    if category == "Cf":
        return True
    return after and (category in ("Mn", "Mc", "Me") or 0x1F3FB <= ord(char) <= 0x1F3FF)


def _check_boundaries(text, needle):
    start = text.find(needle)
    while start >= 0:
        end = start + len(needle)
        if (end < len(text) and _joins_grapheme(text[end], True)) or (start > 0 and _joins_grapheme(text[start - 1], False)):
            raise RenderError("%s next to a combining or format character at offset %d" % (needle, start))
        start = text.find(needle, start + 1)


def _replace(text, needle, value):
    _check_boundaries(text, needle)
    return text.replace(needle, value)


def _swift_has_newline_suffix(text):
    """Swift `hasSuffix("\\n")`: "\\r\\n" is one Character, which is not "\\n"."""
    return text.endswith("\n") and not text.endswith("\r\n")


def filled(template, profile):
    """`BotManagerText.filled(_:managerProfile:)`: `{{MANAGER_ENV}}`, then `{{MANAGER}}`."""
    text = _replace(template, "{{CONNECTOR_RUNNER}}", install_path(MANAGER_SKILL, profile) + "/scripts/default-connectors.py")
    return _replace(_replace(text, "{{MANAGER_ENV}}", env_path(profile)), "{{MANAGER}}", profile)


def _check_args(skill, profile, coding_order):
    if not isinstance(skill, Skill) or skill.version is None or parse_version(skill.version) != skill.version:
        raise RenderError("not a loaded skill")
    if not is_valid_profile_name(profile):
        raise RenderError("invalid profile name")
    if coding_order not in CODING_ORDERS:
        raise RenderError("unknown coding order")


def render_skill(skill, profile, manager_template, coding_order=STANDARD_ORDER):
    """`SkillLibrary.render(_:forProfile:managerTemplate:codingOrder:)`: the SKILL.md for `profile`, or None when the
    template needs `{{MANAGER_TEXT}}` and no manager template is given."""
    _check_args(skill, profile, coding_order)
    text = _replace(skill.template, "{{VERSION}}", skill.version)
    _check_boundaries(text, "{{MANAGER_TEXT}}")
    if "{{MANAGER_TEXT}}" in text:
        if manager_template is None:
            return None
        manager = filled(manager_template, profile).strip(SWIFT_WHITESPACES_AND_NEWLINES)
        text = text.replace("{{MANAGER_TEXT}}", manager)
    text = _replace(text, "{{CODING_ORDER}}", coding_order)
    text = _replace(text, "{{SKILL_DIR}}", install_path(skill.name, profile))
    text = _replace(text, "{{BOT}}", profile)
    return text if _swift_has_newline_suffix(text) else text + "\n"


def render_file(file, profile):
    """`SkillLibrary.render(_ file:forProfile:)`: `references/` files get the manager placeholders, others ship as is."""
    if not is_valid_profile_name(profile):
        raise RenderError("invalid profile name")
    return SkillFile(file.path, filled(file.content, profile)) if file.path.startswith("references/") else file


def variant(skill, coding_order):
    """`SkillLibrary.variant(of:codingOrder:)`: the coding order for a skill that renders one, else None."""
    return coding_order if "{{CODING_ORDER}}" in skill.template else None


def install_files(skill, profile, manager_template, coding_order=STANDARD_ORDER):
    """The files the app's install turn writes into `install_path(skill.name, profile)` (AppStore+Skills.swift
    `skillInstallCommands`): SKILL.md then the rendered extra files, each ending in a newline the Swift way. None when
    SKILL.md cannot be rendered."""
    content = render_skill(skill, profile, manager_template, coding_order)
    if content is None:
        return None
    files = [SkillFile("SKILL.md", content)] + [render_file(f, profile) for f in skill.files]
    return [SkillFile(f.path, f.content if _swift_has_newline_suffix(f.content) else f.content + "\n") for f in files]


def frontmatter(text):
    """`SkillLibrary.frontmatter`: top-level `key: value` lines of a leading `---` block, values trimmed of
    `.whitespaces` then of `"`. A later duplicate key wins."""
    lines = text.split("\n")
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        return {}
    block = lines[1:lines.index("---", 1)]
    for line in block:
        if "\r" in line or "﻿" in line or any(_joins_grapheme(c, True) for c in line):
            raise RenderError("frontmatter character Swift may read differently")
    fields = {}
    for line in block:
        if line.startswith(" ") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        fields[key] = value.strip(SWIFT_WHITESPACES).strip('"')
    return fields


def _read_text(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data.startswith(b"\xef\xbb\xbf"):
        raise RenderError("byte order mark in %s" % path)
    return data.decode("utf-8")


def extra_files(folder):
    """`SkillLibrary.extraFiles(in:)`: every regular file under `folder` except the top SKILL.md, sorted by path,
    dot files and dot folders skipped. None when one is not UTF-8 text or has an unsafe path. Stricter than the app:
    a symlink or other non-regular entry also gives None (the updater only stages regular files)."""
    files = []
    for directory, folders, names in os.walk(folder):
        folders[:] = sorted(f for f in folders if not f.startswith("."))
        for entry in folders + names:
            full = os.path.join(directory, entry)
            mode = os.lstat(full).st_mode
            if entry.startswith(".") or stat.S_ISDIR(mode):
                continue
            path = os.path.relpath(full, folder).replace(os.sep, "/")
            if not stat.S_ISREG(mode) or not is_safe_relative_path(path):
                return None
            if path == "SKILL.md":
                continue
            try:
                files.append(SkillFile(path, _read_text(full)))
            except (UnicodeDecodeError, RenderError):
                return None
    return sorted(files, key=lambda f: f.path.encode("utf-8"))


def load_skill(folder, name, manager_references=None):
    """One skill of `bundled(in:managerReferences:)`: None when SKILL.md is unreadable, its `name` is not `name` or
    not a valid profile name, its version does not parse, an extra file is not installable, or (manager skill only)
    `manager_references` is None. The manager skill gets the references merged in, sorted by path."""
    folder = os.path.join(folder, name)
    try:
        template = _read_text(os.path.join(folder, "SKILL.md"))
    except (OSError, UnicodeDecodeError, RenderError):
        return None
    fields = frontmatter(template)
    version = parse_version(fields.get("version"))
    if fields.get("name") != name or not is_valid_profile_name(name) or version is None:
        return None
    files = extra_files(folder)
    if files is None:
        return None
    if name == MANAGER_SKILL:
        if manager_references is None:
            return None
        files = sorted(files + list(manager_references), key=lambda f: f.path.encode("utf-8"))
    return Skill(name, version, template, tuple(files))


def load_manager_references(bot_manager_folder):
    """`BotManagerText.referenceFiles()`: `recipes/<name>.md` as `references/<name>.md`; None when one is missing or
    empty (`template(candidates:)` treats an empty file as absent)."""
    files = []
    for recipe in RECIPES:
        try:
            content = _read_text(os.path.join(bot_manager_folder, "recipes", recipe + ".md"))
        except (OSError, UnicodeDecodeError, RenderError):
            return None
        if not content:
            return None
        files.append(SkillFile("references/%s.md" % recipe, content))
    return files
