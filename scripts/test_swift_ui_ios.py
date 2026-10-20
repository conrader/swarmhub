"""P7c parity guard for the iOS SDUI renderer, without Swift.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_ui_ios.py

The Mac (P7b) and iOS (P7c) renderers draw the same SwarmHubCore render tree and share SDUIInteraction and
SDUIActionRouter, so their render goldens and action goldens are produced by one Swift code path that runs on macOS
(`swift test`) and on the iOS simulator (`scripts/test-ios-sdui.sh`). This checks, on Linux: the action goldens
(ui-render/actions/) against the Python statement, that both platform views cover the whole catalogue and keep no
behaviour of their own, the iOS wiring (compiled views unchanged with no bundle or the kill switch), the text and
link rules, the generated Xcode project, and the review notes. It checks expectations and source rules, not Swift
execution.
"""

from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Packages/SwarmHubCore/Sources/SwarmHubCore"
TESTS = ROOT / "Packages/SwarmHubCore/Tests/SwarmHubCoreTests"
MAC = ROOT / "Sources/AgentApp/SDUI"
IOS = ROOT / "Apps/iOS/Sources/SDUI"
FIXTURE = ROOT / "Tests/Fixtures/release-bundles/ui-render"
sys.path.insert(0, str(ROOT / "scripts/release"))
import jcs  # noqa: E402
import make_ui_renders  # noqa: E402
import ui_actions  # noqa: E402
import ui_reference as ref  # noqa: E402
sys.path.insert(0, str(ROOT / "scripts"))
from test_swift_ui_vectors import FORBIDDEN  # noqa: E402


def sources(directory):
    return {p.name: p.read_text(encoding="utf-8") for p in sorted(directory.glob("*.swift"))}


MAC_SOURCES = sources(MAC)
IOS_SOURCES = sources(IOS)
CATALOG = (CORE / "SDUI/SDUICatalog.swift").read_text(encoding="utf-8")
TREE = (CORE / "SDUIRender/SDUIRenderTree.swift").read_text(encoding="utf-8")
STATE = (CORE / "SDUIRender/SDUIInteraction.swift").read_text(encoding="utf-8")
GOLDEN_TEST = (TESTS / "SDUIActionGoldenTests.swift").read_text(encoding="utf-8")


def enum_cases(source, name):
    body = re.search(r"public enum " + name + r"\b[^{]*\{(.*?)\n\}", source, re.S).group(1)
    names = []
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("case "):
            names += [re.match(r"\w+", part.strip()).group(0) for part in re.sub(r"\([^)]*\)", "", line[5:]).split(",")]
    return names


def member(source, signature):
    """The text of one `private var/func` member, from its signature to its closing brace at four spaces."""
    return re.search(r"    " + re.escape(signature) + r".*?\n    \}\n", source, re.S).group(0)


class ActionGoldenTests(unittest.TestCase):
    def test_every_golden_document_has_action_text(self):
        vectors = jcs.loads((ROOT / "Tests/Fixtures/release-bundles/ui/vectors.json").read_bytes())
        renders = {c["id"] for c in vectors["cases"] if c["expect"]["verdict"] == "render"}
        present = {p.stem for p in (FIXTURE / "actions").glob("*.txt")}
        self.assertEqual(present, renders)
        self.assertEqual({p.stem for p in (FIXTURE / "actions/targets").glob("*.txt")}, set(make_ui_renders.TARGETS))
        self.assertEqual(sorted(p.name for p in (FIXTURE / "actions/cases").iterdir()), ["edges.json", "edges.txt"])
        # The Swift suite reads the same directories.
        for path in ('"actions/\\(vector.id).txt"', '"actions/cases/edges.json"', '"actions/\\(name).txt"'):
            self.assertIn(path, GOLDEN_TEST)

    def test_action_text_matches_the_python_statement(self):
        context = jcs.loads((FIXTURE / "context.json").read_bytes())
        edges = (FIXTURE / "actions/cases/edges.json").read_bytes()
        self.assertEqual(ref.decode(edges, "p7c_action_edges"), {"verdict": "render"})
        self.assertEqual(ui_actions.describe(jcs.loads(edges), context),
                         (FIXTURE / "actions/cases/edges.txt").read_text(encoding="utf-8"))

    def test_goldens_reach_every_confirmation_and_refusal_the_router_has(self):
        text = "".join(p.read_text(encoding="utf-8") for p in (FIXTURE / "actions").rglob("*.txt"))
        reasons = set(re.findall(r"refused (\w+)", text))
        router = (CORE / "SDUIRender/SDUIActionRouter.swift").read_text(encoding="utf-8")
        declared = set(re.findall(r'\.refused\("(\w+)"\)', router)) | set(re.findall(r'problems\[field\.id\] = "(\w+)"', router))
        # Unreachable through a decoded document: the decoder already refuses these shapes.
        unreachable = {"submit_outside_form", "url_not_allowed", "unknown_screen", "not_a_submit"}
        self.assertEqual(reasons, declared - unreachable)
        for effect in ("accept: move_flow +1", "accept: move_flow -1", "accept: perform open_url",
                       "accept: perform routine.save", "available=no press: refused routine_unavailable"):
            self.assertIn(effect, text)

    def test_python_statement_mirrors_the_router_text(self):
        router = (CORE / "SDUIRender/SDUIActionRouter.swift").read_text(encoding="utf-8")
        self.assertIn('SDUIConfirmation(title: label + "?", message: "", button: label, action: pending)', router)
        self.assertIn('SDUIConfirmation(title: "Open this link?", message: url.absoluteString, button: "Open"', router)
        view_source = (CORE / "SDUIRender/SDUIViewSource.swift").read_text(encoding="utf-8")
        self.assertIn(f"public static let maxName = {ui_actions.MAX_NAME}", view_source)
        self.assertIn(f"public static let maxPrompt = {ui_actions.MAX_PROMPT}", view_source)


class PlatformParityTests(unittest.TestCase):
    def test_both_platforms_draw_every_catalogue_element(self):
        elements = enum_cases(TREE, "SDUIElement")
        self.assertEqual(len(elements), 10)
        for platform in (MAC_SOURCES, IOS_SOURCES):
            view = platform["SDUIDocumentView.swift"]
            for name in elements:
                self.assertIn(f"case .{name}(", view, name)

    def test_both_platforms_cover_every_style_kind_and_tone(self):
        for platform in (MAC_SOURCES, IOS_SOURCES):
            view, form = platform["SDUIDocumentView.swift"], platform["SDUIFormView.swift"]
            for enum in ("SDUITextStyle", "SDUITextRole", "SDUITone", "SDUIListStyle", "SDUIButtonStyle"):
                for name in enum_cases(CATALOG, enum):
                    self.assertIn(f"case .{name}", view, f"{enum}.{name}")
            for name in enum_cases(CATALOG, "SDUIFieldKind"):
                self.assertIn(f"case .{name}:", form, name)

    def test_behaviour_lives_only_in_the_shared_core(self):
        mac, ios = MAC_SOURCES["SDUIDocumentView.swift"], IOS_SOURCES["SDUIDocumentView.swift"]
        for signature in ("private var confirming", "private var context", "private func resolve", "private func run"):
            self.assertEqual(member(mac, signature), member(ios, signature), signature)
        context = re.compile(r"struct SDUINodeContext \{.*?\n\}", re.S)
        self.assertEqual(context.search(mac).group(0), context.search(ios).group(0))
        for name, source in list(MAC_SOURCES.items()) + list(IOS_SOURCES.items()):
            for logic in ("router.route(", "router.submit(", ".resolve(accepted:", "fieldProblems(", "SDUIRenderer.tree(",
                          "steps[flow", "steps[key]", "@State private var forms", "@State private var busy"):
                self.assertFalse(logic in source, f"{name}: {logic}")
        for source in (mac, ios):
            self.assertIn("@State private var interaction = SDUIInteraction()", source)
            self.assertIn("if let root = interaction.tree(document, data: data)", source)
        for form in (MAC_SOURCES["SDUIFormView.swift"], IOS_SOURCES["SDUIFormView.swift"]):
            self.assertIn("!context.isAvailable(form.submit, nil)", form)
        # Binding paths come from SDUIRoutineTarget.editorData / cardData, not from either app.
        for hosts in (MAC_SOURCES["RoutineSDUIHosts.swift"], IOS_SOURCES["RoutineSDUIHosts.swift"]):
            self.assertNotRegex(hosts, r'"(routine|result|profile)\.\w+"')
        self.assertIn("SDUIRoutineTarget.cardData(result,", MAC_SOURCES["RoutineSDUIHosts.swift"])
        self.assertIn("SDUIRoutineTarget.editorData(profile:", MAC_SOURCES["RoutineSDUIHosts.swift"])

    def test_shared_state_keeps_the_mac_rules(self):
        handle = re.search(r"mutating func handle\(.*?\n    \}", STATE, re.S).group(0)
        self.assertIn("failure = nil", handle)
        self.assertIn("steps[flow.key] = min(max((steps[flow.key] ?? 0) + delta, 0), max(flow.count - 1, 0))", handle)
        self.assertIn("guard let flow else { return nil }", handle)
        start = re.search(r"public mutating func start\(.*?\n    \}", STATE, re.S).group(0)
        self.assertIn("confirmation = nil", start)
        self.assertIn("guard actions.isAvailable(command), !busy else { return false }", start)
        self.assertNotRegex(STATE, r"\bimport\s+(AppKit|UIKit|SwiftUI)\b")


class IOSWiringTests(unittest.TestCase):
    def test_compiled_views_unchanged_without_a_document(self):
        hosts = IOS_SOURCES["RoutineSDUIHosts.swift"]
        self.assertEqual(hosts.count("case .compiled: compiled()"), 2)
        self.assertEqual(hosts.count("case .updateRequired: SDUIUpdateRequiredView("), 2)
        self.assertIn("switch SDUIRoutineTarget.resultCard(source)", hosts)
        self.assertIn("switch SDUIRoutineTarget.editor(source, routineID: routineID, data: data)", hosts)
        source = IOS_SOURCES["SDUIiOSSource.swift"]
        self.assertIn("static let defaultValue = SDUIViewSource.compiledOnly", source)
        self.assertIn("static let urlHosts: Set<String> = []", source)
        self.assertIn("FileManager.default.fileExists(atPath: root.path) else { return .compiledOnly }", source)
        app = (ROOT / "Apps/iOS/Sources/SwarmHubApp.swift").read_text(encoding="utf-8")
        self.assertIn(".environment(\\.sduiViewSource, SDUIiOS.installed)", app)
        # No iOS screen mounts a routine host yet (iOS has no compiled routine views); see the review notes.
        others = "".join(p.read_text(encoding="utf-8") for p in (ROOT / "Apps/iOS/Sources").glob("*.swift"))
        self.assertNotIn("RoutineResultCardHost(", others)
        self.assertNotIn("RoutineEditorHost(", others)

    def test_ios_sink_offers_only_existing_ios_paths(self):
        hosts = IOS_SOURCES["RoutineSDUIHosts.swift"]
        available = re.search(r"func isAvailable\(_ command: SDUIAppCommand\) -> Bool \{(.*?)\n    \}", hosts, re.S).group(1)
        self.assertIn("case .dismiss: return dismiss != nil", available)
        self.assertIn("case .copyText, .openURL: return true", available)
        self.assertIn(".routineCreate, .routineSave:\n            return false", available)
        self.assertEqual(hosts.count("UIApplication.shared.open("), 1)
        self.assertIn("case .openURL(let url): _ = await UIApplication.shared.open(url)", hosts)
        self.assertIn("router: SDUIActionRouter(urlHosts: policy.urlHosts)", hosts)

    def test_ios_text_is_never_interpreted_as_links_or_code(self):
        for name, source in IOS_SOURCES.items():
            for symbol in FORBIDDEN:
                self.assertFalse(symbol in source, f"{name}: {symbol}")
            for call in re.findall(r"\bText\((?!verbatim:)([^)]{0,40})", source):
                self.assertTrue(call.startswith("SDUIRenderText.inline("), f"{name}: Text({call}")
            for banned in ("Link(", "LocalizedStringKey", "AttributedString(markdown", ".textSelection(", "\\.openURL",
                           "dataDetectorTypes", "NSDataDetector", "import AppKit"):
                self.assertFalse(banned in source, f"{name}: {banned}")
            self.assertNotRegex(source, r"\bUITextView\b|\bUILabel\b")
            self.assertNotIn("Label(\"", source, name)
        self.assertIn("case .markdown: Text(SDUIRenderText.inline(text))", IOS_SOURCES["SDUIDocumentView.swift"])

    def test_project_builds_every_ios_sdui_file(self):
        project = (ROOT / "Apps/iOS/SwarmHub.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertGreaterEqual(len(IOS_SOURCES), 4)
        for name in IOS_SOURCES:
            self.assertIn(f'path = "Sources/SDUI/{name}"', project)
        self.assertIn("(APP / 'Sources').rglob('*.swift')", (ROOT / "scripts/generate-ios-project.py").read_text(encoding="utf-8"))

    def test_review_notes_and_sizes(self):
        notes = (ROOT / "docs/ios/APP-REVIEW-NOTES-SDUI.md").read_text(encoding="utf-8")
        for text in ("2.5.2", "2.3.1", "§5.3", "Re-read guideline 2.5.2", "routine_result_card", "routine_create_form",
                     "routine_form"):
            self.assertIn(text, notes)
        files = list(IOS.glob("*.swift")) + list(MAC.glob("*.swift")) + list((CORE / "SDUIRender").glob("*.swift"))
        files += [TESTS / "SDUIActionGoldenTests.swift", TESTS / "SDUIInteractionTests.swift", Path(__file__),
                  ROOT / "scripts/release/ui_actions.py", ROOT / "scripts/test-ios-sdui.sh"]
        for path in files:
            self.assertLessEqual(len(path.read_text(encoding="utf-8").splitlines()), 500, path.name)


if __name__ == "__main__":
    print(f"iOS SDUI sources: {len(IOS_SOURCES)}, action goldens: "
          f"{len(list((FIXTURE / 'actions').rglob('*.txt')))}", flush=True)
    unittest.main()
