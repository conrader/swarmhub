"""P7a parity guard: SDUI catalogue v1 verdicts and Swift source rules, without Swift.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_ui_vectors.py

Runs every golden document under Tests/Fixtures/release-bundles/ui/ through the Python reference
(scripts/release/ui_reference.py), replays the shared fuzz, checks byte-identical regeneration, and compares the
Swift decoder's vocabulary, limits, patterns and fuzz constants with the reference. It also greps the SwarmHubCore
target for script and dynamic-loading symbols. This checks expectations and source rules, not Swift execution: the
Mac run (`swift test`) remains mandatory.
"""

import ast
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Packages/SwarmHubCore"
SDUI = CORE / "Sources/SwarmHubCore/SDUI"
TESTS = CORE / "Tests/SwarmHubCoreTests"
sys.path.insert(0, str(ROOT / "scripts/release"))
import make_ui_vectors  # noqa: E402
import ui_fuzz  # noqa: E402
import ui_reference as ref  # noqa: E402

SOURCES = {path.name: path.read_text(encoding="utf-8") for path in sorted(SDUI.glob("*.swift"))}
CATALOGUE = SOURCES["SDUICatalog.swift"]
SUPPORT = (TESTS / "SDUITestSupport.swift").read_text(encoding="utf-8")
DECODER_TEST = (TESTS / "SDUIDecoderTests.swift").read_text(encoding="utf-8")
FUZZ_TEST = (TESTS / "SDUIFuzzTests.swift").read_text(encoding="utf-8")
FIXTURE_PATH = re.search(r'static let vectorFixture = "([^"]+)"', SUPPORT).group(1)
FUZZ_PATH = re.search(r'static let fuzzFixture = "([^"]+)"', SUPPORT).group(1)
VECTORS = json.loads((ROOT / FIXTURE_PATH).read_text(encoding="utf-8"))
FUZZ = json.loads((ROOT / FUZZ_PATH).read_text(encoding="utf-8"))
UI = (ROOT / FIXTURE_PATH).parent
FORBIDDEN = ["JavaScriptCore", "JSContext", "JSValue", "JSVirtualMachine", "WebKit", "WKWebView", "dlopen", "dlsym",
             "NSClassFromString", "NSSelectorFromString", "objc_getClass", "objc_lookUpClass", "objc_msgSend",
             "NSInvocation", "NSExpression", "NSPredicate", "CFBundleLoadExecutable", "loadAndReturnError",
             "Bundle(path:", "Bundle(url:", "#selector", "value(forKey", "@_dynamicReplacement"]


def swift_strings(text):
    """Swift string literals in order, unescaped (only \\\\ and \\" occur in these sources)."""
    return [s.replace('\\\\', '\\').replace('\\"', '"') for s in re.findall(r'"((?:[^"\\]|\\.)*)"', text)]


def swift_enum(name):
    body = re.search(r"enum " + name + r": String, CaseIterable, Sendable \{\n(.*?)\n\n|enum " + name
                     + r": String, CaseIterable, Sendable \{\n(.*?)\n\}", CATALOGUE, re.S)
    text = body.group(1) or body.group(2)
    values = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("case "):
            break
        for item in line[5:].split(","):
            case, _, raw = item.strip().partition(" = ")
            values.append(ast.literal_eval(raw) if raw else case)
    return values


def swift_static(name, source=CATALOGUE):
    match = re.search(r"static let " + name + r"(?:: [^=]+)? = (\[.*?\]|\"(?:[^\"\\]|\\.)*\"|[0-9_]+)\n", source, re.S)
    text = match.group(1)
    if text.startswith("["):
        return swift_strings(text)
    if text.startswith('"'):
        return swift_strings(text)[0]
    return int(text.replace("_", ""))


class GoldenVectorTests(unittest.TestCase):
    pass


def golden_test(case):
    def test(self):
        i = case["inputs"]
        data = (UI / i["document"]).read_bytes()
        self.assertEqual(ref.decode(data, i["view"], i["limits"], i["url_hosts"], i["killed"]), case["expect"])
    return test


for _case in VECTORS["cases"]:
    setattr(GoldenVectorTests, "test_" + _case["id"].replace("-", "_"), golden_test(_case))


class FixtureTests(unittest.TestCase):
    def test_regeneration_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as temp:
            make_ui_vectors.write(Path(temp))
            self.assertEqual(make_ui_vectors.differences(Path(temp), ROOT / "Tests/Fixtures/release-bundles"), [])

    def test_catalogue_covers_every_reason_and_outcome(self):
        self.assertEqual(FIXTURE_PATH, "Tests/Fixtures/release-bundles/ui/vectors.json")
        self.assertEqual(VECTORS["reasons"], list(ref.REASONS))
        ids = [case["id"] for case in VECTORS["cases"]]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(len(ids), len({value.replace("-", "_") for value in ids}))
        reasons = {case["expect"].get("reason") for case in VECTORS["cases"]} - {None}
        self.assertEqual(reasons, set(ref.REASONS))
        verdicts = {case["expect"]["verdict"] for case in VECTORS["cases"]}
        self.assertEqual(verdicts, {"render", "fallback", "update_required"})

    def test_shared_fuzz_replays_identically(self):
        replay = make_ui_vectors.fuzz(VECTORS["cases"], {c["inputs"]["document"]: (UI / c["inputs"]["document"])
                                                         .read_bytes() for c in VECTORS["cases"]},
                                      seed=FUZZ["seed"], iterations=FUZZ["iterations"])
        self.assertEqual(replay, FUZZ)
        self.assertLess(FUZZ["seed"], 2**53)  # read by JSONDecoder as UInt64 on the Mac
        labels = set(FUZZ["expected"])
        self.assertIn("render", labels)
        self.assertTrue(labels <= {"render", "skip"} | {f"{v}/{r}" for v in ("fallback", "update_required")
                                                         for r in ref.REASONS})

    def test_more_seeds_never_raise(self):
        files = {c["inputs"]["document"]: (UI / c["inputs"]["document"]).read_bytes() for c in VECTORS["cases"]}
        for seed in (1, 0xDEADBEEF, 0x5EED000000000001):
            result = make_ui_vectors.fuzz(VECTORS["cases"], files, seed=seed, iterations=1000)
            self.assertEqual(len(result["expected"]), 1000)


class SwiftParityTests(unittest.TestCase):
    def test_markup_bytes_match_the_reference(self):
        self.assertEqual(swift_static("markupForbidden"), ref.MARKUP_FORBIDDEN)
        source = SOURCES["SDUIDecoder+Values.swift"]
        self.assertIn('try sduiRequire(!text.utf8.contains { SDUICatalog.markupForbidden.utf8.contains($0) }, '
                      '"markup_not_allowed")', source)

    def test_vocabulary_matches_the_reference(self):
        self.assertEqual(set(swift_enum("SDUIComponentType")), ref.COMPONENTS)
        self.assertEqual(set(swift_enum("SDUITextStyle")), ref.TEXT_STYLES)
        self.assertEqual(set(swift_enum("SDUITextRole")), ref.TEXT_ROLES)
        self.assertEqual(set(swift_enum("SDUITone")), ref.BADGE_TONES)
        self.assertEqual(set(swift_enum("SDUIListStyle")), ref.LIST_STYLES)
        self.assertEqual(set(swift_enum("SDUIButtonStyle")), ref.BUTTON_STYLES)
        self.assertEqual(set(swift_enum("SDUIFieldKind")), ref.FIELD_KINDS)
        self.assertEqual(set(swift_enum("SDUICommand")), set(ref.COMMANDS))
        self.assertEqual(set(swift_enum("SDUIScreen")), ref.SCREENS)
        for name, expected in (("bindingRoots", ref.BIND_ROOTS), ("bindingWords", ref.BINDING_WORDS),
                               ("commonMembers", ref.COMMON), ("fieldMembers", ref.FIELD_MEMBERS)):
            self.assertEqual(set(swift_static(name)), expected, name)
        self.assertEqual(tuple(swift_static("surfaceFragments")), ref.SURFACE_FRAGMENTS)
        self.assertEqual(tuple(swift_static("bindingFragments")), ref.BINDING_FRAGMENTS)

    def test_patterns_and_limits_match_the_reference(self):
        for swift, python in (("namePattern", ref.NAME), ("bindingPattern", ref.BINDING), ("optionPattern", ref.OPTION),
                              ("fileTypePattern", ref.FILE_TYPE), ("urlPattern", ref.URL)):
            self.assertEqual(swift_static(swift), python, swift)
        for swift, python in (("maxURLBytes", ref.MAX_URL_BYTES), ("maxTotal", ref.MAX_TOTAL),
                              ("maxLines", ref.MAX_LINES), ("maxFileTypes", ref.MAX_FILE_TYPES)):
            self.assertEqual(swift_static(swift), python, swift)
        limits = dict(re.findall(r"public var (max\w+) = ([0-9_]+)", CATALOGUE))
        snake = {re.sub(r"(?<!^)(?=[A-Z])", "_", k).lower(): int(v.replace("_", "")) for k, v in limits.items()}
        self.assertEqual(snake, ref.LIMITS)

    def test_component_members_and_commands_match_the_reference(self):
        table = re.findall(r"case \.(\w+): return \((\[[^\]]*\]), (\[[^\]]*\])\)", CATALOGUE)
        names = dict(zip([c.replace("_", "") for c in swift_enum("SDUIComponentType")], swift_enum("SDUIComponentType")))
        members = {names[case.lower()]: (set(swift_strings(req)), set(swift_strings(opt))) for case, req, opt in table}
        self.assertEqual(members, ref.PROPS)
        argument = re.search(r"var argument: String\? \{(.*?)\n    \}", CATALOGUE, re.S).group(1)
        swift_cases = {}
        raw = {c.replace("_", "").replace(".", "").lower(): c for c in swift_enum("SDUICommand")}
        for cases, result in re.findall(r"case ([^:]+): return (\"\w+\"|nil)", argument):
            for case in cases.split(","):
                swift_cases[raw[case.strip().lstrip(".").lower()]] = None if result == "nil" else result.strip('"')
        self.assertEqual(swift_cases, ref.COMMANDS)
        self.assertIn("var isFormSubmit: Bool { self == .routineCreate || self == .routineSave }", CATALOGUE)
        self.assertIn("var isFlowStep: Bool { self == .flowNext || self == .flowBack }", CATALOGUE)
        self.assertEqual(ref.FORM_COMMANDS, {"routine.create", "routine.save"})
        self.assertEqual(ref.FLOW_COMMANDS, {"flow_next", "flow_back"})

    def test_reasons_in_swift_are_the_reference_reasons(self):
        text = "\n".join(SOURCES.values())
        used = set(re.findall(r'(?:reason: |,\s*)"([a-z_]+)"\)', text)) | set(re.findall(r'\?\? "([a-z_]+)"', text))
        self.assertEqual(used, set(ref.REASONS))

    def test_fuzz_port_constants_match_the_reference(self):
        interesting = [int(v) for v in re.search(r"static let interesting: \[UInt8\] = \[(.*?)\]", FUZZ_TEST, re.S)
                       .group(1).replace("\n", " ").split(",")]
        self.assertEqual(bytes(interesting), ui_fuzz.INTERESTING)
        self.assertEqual(swift_static("types", FUZZ_TEST), ui_fuzz.TYPES)
        pool = re.search(r"static let pool: \[JCS.Value\] = \[(.*?)\]\n", FUZZ_TEST, re.S).group(1)
        items = []
        for kind, value in re.findall(r"\.(string|integer|bool|array|object)\(((?:\"(?:[^\"\\]|\\.)*\")|[^)]*)\)", pool):
            items.append({"string": lambda v: swift_strings(v)[0], "integer": lambda v: int(v.replace("_", "")),
                          "bool": lambda v: v == "true", "array": lambda v: [], "object": lambda v: {}}[kind](value))
        self.assertEqual(items, ui_fuzz.POOL)
        for constant in ("0x9E37_79B9_7F4A_7C15", "0xBF58_476D_1CE4_E5B9", "0x94D0_49BB_1331_11EB"):
            self.assertIn(constant, FUZZ_TEST)
        self.assertIn("labels == fuzz.expected", FUZZ_TEST)
        self.assertIn("for vector in catalog.cases {", DECODER_TEST)

    def test_target_has_no_script_or_dynamic_loading_symbols(self):
        self.assertEqual(swift_static("forbidden", DECODER_TEST), FORBIDDEN)
        files = sorted((CORE / "Sources").rglob("*.swift")) + [CORE / "Package.swift"]
        self.assertTrue(any(p.name == "SDUIDecoder.swift" for p in files))
        for path in files:
            text = path.read_text(encoding="utf-8")
            for symbol in FORBIDDEN:
                self.assertNotIn(symbol, text, f"{path.relative_to(ROOT)}: {symbol}")

    def test_sources_are_ios_safe_and_under_500_lines(self):
        tests = [TESTS / n for n in ("SDUITestSupport.swift", "SDUIDecoderTests.swift", "SDUIFuzzTests.swift")]
        scripts = [Path(__file__), ROOT / "scripts/release/ui_reference.py", ROOT / "scripts/release/ui_fuzz.py",
                   ROOT / "scripts/release/ui_cases.py",
                   ROOT / "scripts/release/make_ui_vectors.py"]
        for path in list(SDUI.glob("*.swift")) + tests + scripts:
            source = path.read_text(encoding="utf-8")
            self.assertLessEqual(len(source.splitlines()), 500, path.name)
            if path.suffix == ".swift":
                self.assertNotRegex(source, r"\bimport\s+(AppKit|UIKit|SwiftUI)\b|\bProcess\s*\(")
        self.assertTrue("## 13. View documents" in (ROOT / "docs/update-service/SCHEMAS.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    print(f"SDUI catalogue: {len(VECTORS['cases'])} golden documents, {FUZZ['iterations']} shared fuzz iterations",
          flush=True)
    unittest.main()
