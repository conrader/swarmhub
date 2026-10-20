"""P7b parity and safety guard for the SDUI renderer, without Swift.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_ui_render.py

Regenerates the render goldens (Tests/Fixtures/release-bundles/ui-render/) from the Python statement
(scripts/release/ui_render.py) and compares them byte for byte, then checks the Swift sources for the rules that
cannot be seen in a golden: renderer defaults, text drawn without link interpretation, open_url only behind the
allowlist and a confirmation, no approval or secret destination, the four Mac wiring cases, file sizes. This checks
expectations and source rules, not Swift execution: the Mac run (`swift test`) remains mandatory.
"""

import copy
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Packages/SwarmHubCore"
RENDER = CORE / "Sources/SwarmHubCore/SDUIRender"
TESTS = CORE / "Tests/SwarmHubCoreTests"
MAC = ROOT / "Sources/AgentApp/SDUI"
sys.path.insert(0, str(ROOT / "scripts/release"))
import jcs  # noqa: E402
import make_ui_renders  # noqa: E402
import ui_cases  # noqa: E402
import ui_reference as ref  # noqa: E402
import ui_render  # noqa: E402
sys.path.insert(0, str(ROOT / "scripts"))
from test_swift_ui_vectors import FORBIDDEN  # noqa: E402

CORE_SOURCES = {p.name: p.read_text(encoding="utf-8") for p in sorted(RENDER.glob("*.swift"))}
MAC_SOURCES = {p.name: p.read_text(encoding="utf-8") for p in sorted(MAC.glob("*.swift"))}
RENDER_TEST = (TESTS / "SDUIRenderTreeTests.swift").read_text(encoding="utf-8")
FIXTURE = re.search(r'static let renderFixture = "([^"]+)"', RENDER_TEST).group(1)
VECTORS = json.loads((ROOT / "Tests/Fixtures/release-bundles/ui/vectors.json").read_text(encoding="utf-8"))


class GoldenTests(unittest.TestCase):
    def test_regeneration_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as temp:
            make_ui_renders.write(Path(temp))
            self.assertEqual(make_ui_renders.differences(Path(temp), ROOT / "Tests/Fixtures/release-bundles"), [])

    def test_every_render_case_has_a_golden_and_nothing_else(self):
        self.assertEqual(FIXTURE, "Tests/Fixtures/release-bundles/ui-render")
        renders = {c["id"] + ".txt" for c in VECTORS["cases"] if c["expect"]["verdict"] == "render"}
        self.assertGreaterEqual(len(renders), 10)
        present = {p.name for p in (ROOT / FIXTURE).glob("*.txt")}
        self.assertEqual(present, renders)
        targets = {p.name for p in (ROOT / FIXTURE / "targets").iterdir()}
        self.assertEqual(targets, {f"{n}.{e}" for n in make_ui_renders.TARGETS for e in ("json", "txt")})

    def test_targets_render_with_the_macs_empty_allowlist_and_fit_the_routine_paths(self):
        views = {}
        for name, document in make_ui_renders.TARGETS.items():
            data = (ROOT / FIXTURE / "targets" / f"{name}.json").read_bytes()
            self.assertEqual(ref.decode(data, document["view"], url_hosts=()), {"verdict": "render"}, name)
            views[document["view"]] = jcs.loads(data)
        swift_views = dict(re.findall(r'public static let (\w+View) = "(\w+)"', CORE_SOURCES["SDUIViewSource.swift"]))
        self.assertEqual(set(swift_views.values()), set(views))
        kinds = {"name": {"text"}, "schedule": {"schedule", "text"}, "prompt": {"multiline", "text"}}
        for view, document in views.items():
            forms = [c for c in document["root"]["children"] if c["type"] == "form"]
            if view == "routine_result_card":
                self.assertEqual(forms, [])
                continue
            self.assertEqual(len(forms), 1)
            for field in forms[0]["fields"]:
                self.assertIn(field["kind"], kinds[field["id"]])
            command = forms[0]["submit"]["action"]["command"]
            self.assertEqual(command, "routine.save" if view == "routine_form" else "routine.create")

    def test_hidden_root_and_bound_link_syntax_stay_plain(self):
        doc = {"schema": ref.SCHEMA, "view": "v", "root": {"type": "text", "text": "x",
                                                         "visible_if": {"exists": {"bind": "app.flag"}}}}
        self.assertEqual(ui_render.describe(doc, {}), "(hidden)\n")
        card = (ROOT / FIXTURE / "routine-card.txt").read_text(encoding="utf-8")
        self.assertIn('style=markdown role=body "All **3** checks passed. See [docs](https://example.com)', card)
        self.assertIn("value=10 ", card)  # bound 12 clamped to total 10
        self.assertNotIn("TEST-never-rendered", "".join(p.read_text(encoding="utf-8")
                                                        for p in (ROOT / FIXTURE).rglob("*.txt")))

    def test_flow_confirmation_matches_the_render_reference(self):
        # The reference describes actions; it does not execute them. Absent/false stays immediate in Swift.
        for command, step, child in (("flow_next", 0, 1), ("flow_back", 1, 2)):
            for confirm in (None, False, True):
                with self.subTest(command=command, confirm=confirm):
                    doc = copy.deepcopy(ui_cases.CONNECT_FLOW)
                    action = doc["root"]["steps"][step]["children"][child]["action"]
                    self.assertEqual(action["command"], command)
                    if confirm is not None:
                        action["confirm"] = confirm
                    self.assertEqual(ref.decode(jcs.canonical(doc), doc["view"]), {"verdict": "render"})
                    line = next(line for line in ui_render.describe(doc, {}).splitlines() if "-> " + command in line)
                    self.assertEqual(line.endswith(" confirm"), confirm is True)

    def test_form_submit_confirmation_matches_the_render_reference(self):
        for target in ("routine-create-form", "routine-edit-form"):
            for confirm in (None, False, True):
                with self.subTest(target=target, confirm=confirm):
                    doc = copy.deepcopy(make_ui_renders.TARGETS[target])
                    action = doc["root"]["children"][0]["submit"]["action"]
                    if confirm is not None:
                        action["confirm"] = confirm
                    self.assertEqual(ref.decode(jcs.canonical(doc), doc["view"]), {"verdict": "render"})
                    line = next(line for line in ui_render.describe(doc, {}).splitlines() if "submit " in line)
                    self.assertEqual(line.endswith(" confirm"), confirm is True)


class SwiftSourceTests(unittest.TestCase):
    def test_renderer_defaults_match_the_python_statement(self):
        tree = CORE_SOURCES["SDUIRenderTree.swift"]
        for snippet in ("style ?? .plain, role: role ?? .body", "tone: tone ?? .neutral", "style: style ?? .plain)",
                        "style: style ?? .secondary", "public static let defaultTotal: Int64 = 100",
                        "maxLines ?? SDUICatalog.maxLines", "min(max(number, 0), total)",
                        'split(separator: "\\n", omittingEmptySubsequences: false)'):
            self.assertIn(snippet, tree)
        self.assertEqual(ui_render.DEFAULT_TOTAL, 100)
        self.assertEqual(ui_render.DEFAULT_MAX_LINES, ref.MAX_LINES)
        text = CORE_SOURCES["SDUIRenderText.swift"]
        for escape in ('case "\\\\": out += "\\\\\\\\"', 'case "\\"": out += "\\\\\\""', 'case "\\n": out += "\\\\n"',
                       'case "\\t": out += "\\\\t"', 'case "\\r": out += "\\\\r"', "if scalar.value < 0x20"):
            self.assertIn(escape, text)

    def test_no_script_dynamic_loading_or_ui_imports_in_core(self):
        for name, source in CORE_SOURCES.items():
            for symbol in FORBIDDEN:
                self.assertNotIn(symbol, source, f"{name}: {symbol}")
            self.assertNotRegex(source, r"\bimport\s+(AppKit|UIKit|SwiftUI|WebKit)\b|\bProcess\s*\(")
        for name, source in MAC_SOURCES.items():
            for symbol in FORBIDDEN:
                self.assertNotIn(symbol, source, f"{name}: {symbol}")

    def test_mac_text_is_never_interpreted_as_links(self):
        for name, source in MAC_SOURCES.items():
            for call in re.findall(r"\bText\((?!verbatim:)([^)]{0,40})", source):
                self.assertTrue(call.startswith("SDUIRenderText.inline("), f"{name}: Text({call}")
            for banned in ("Link(", "LocalizedStringKey", "AttributedString(markdown", ".textSelection(", "\\.openURL",
                           "NSWorkspace", "NSDataDetector", "WKWebView"):
                self.assertNotIn(banned, source, f"{name}: {banned}")
        inline = CORE_SOURCES["SDUIRenderText.swift"]
        self.assertIn("interpretedSyntax: .inlineOnlyPreservingWhitespace", inline)
        self.assertIn("text[range].link = nil", inline)
        self.assertIn("text[range].imageURL = nil", inline)
        self.assertIn("case .markdown: Text(SDUIRenderText.inline(text))", MAC_SOURCES["SDUIDocumentView.swift"])

    def test_open_url_only_after_allowlist_and_confirmation(self):
        router = CORE_SOURCES["SDUIActionRouter.swift"]
        branch = re.search(r"case \.openURL:\n(.*?)\n        case \.navigate:", router, re.S).group(1)
        self.assertIn('guard let url = allowedURL(action.argument) else { return .refused("url_not_allowed") }', branch)
        self.assertIn("return .confirm(", branch)
        self.assertIn("guard urlHosts.contains(host)", router)
        self.assertNotRegex(router, r"return\s+\.perform\(\.openURL")
        hosts = MAC_SOURCES["RoutineSDUIHosts.swift"]
        self.assertEqual(len(re.findall(r"ExternalLink\.open\(", "".join(MAC_SOURCES.values()))), 1)
        self.assertIn("case .openURL(let url): ExternalLink.open(url)", hosts)
        self.assertIn("static let urlHosts: Set<String> = []", MAC_SOURCES["SDUIMacSource.swift"])
        self.assertIn("router: SDUIActionRouter(urlHosts: policy.urlHosts)", hosts)

    def test_flow_and_submit_use_the_shared_confirmation_gate(self):
        router = CORE_SOURCES["SDUIActionRouter.swift"]
        for name, delta in (("flowNext", 1), ("flowBack", -1)):
            self.assertIn(f"case .{name}: return confirmed(.moveFlow({delta}), action: action, label: label)", router)
            self.assertNotIn(f"case .{name}: return .moveFlow", router)
        for effect in (".perform(command)", ".perform(.routineCreate(draft))", ".perform(.routineSave(id, draft))"):
            self.assertIn(f"return confirmed({effect}, action:", router)
        self.assertIn("action.requiresConfirmation ? .confirm(confirmation) : confirmation.resolve(accepted: true)", router)
        self.assertIn('guard accepted else { return .refused("confirmation_declined") }', router)
        self.assertIn("case .moveFlow(let delta): return .moveFlow(delta)", router)
        tests = (TESTS / "SDUIActionRouterTests.swift").read_text(encoding="utf-8")
        for regression in ("flowMovesWaitForConfirmation", "everyLocalCommandHonorsConfirmation",
                           "formSubmitsWaitForConfirmationAfterValidation"):
            self.assertIn("@Test func " + regression, tests)

    def test_confirmation_keeps_the_flow_context_until_accept_or_decline(self):
        view = MAC_SOURCES["SDUIDocumentView.swift"]
        self.assertIn("confirmation = PendingConfirmation(request: pending, flow: flow)", view)
        self.assertIn("handle(pending.request.resolve(accepted: accepted), flow: pending.flow)", view)
        self.assertIn("Button { resolve(pending, accepted: true) }", view)
        self.assertIn("Button(role: .cancel) { resolve(pending, accepted: false) }", view)
        available = re.search(r"private func available\(.*?\n    \}", view, re.S).group(0)
        self.assertIn("switch pending.action", available)
        self.assertEqual(available.count("case .moveFlow: return flow != nil"), 2)
        self.assertIn("case .perform(let command): return actions.isAvailable(command)", available)

    def test_form_submit_availability_asks_the_routine_path_not_route(self):
        # route() refuses routine.create/routine.save outside a form; the submit button must not go through it.
        view = MAC_SOURCES["SDUIDocumentView.swift"]
        available = re.search(r"private func available\(.*?\n    \}", view, re.S).group(0)
        self.assertLess(available.index("case .routineCreate: return actions.isAvailable(.routineCreate("),
                        available.index("actions.router.route(action"))
        self.assertIn("case .routineSave: return actions.isAvailable(.routineSave(action.argument", available)
        self.assertIn("!context.isAvailable(form.submit, nil)", MAC_SOURCES["SDUIFormView.swift"])

    def test_no_approval_or_secret_destination(self):
        router = CORE_SOURCES["SDUIActionRouter.swift"]
        body = re.search(r"public enum SDUIAppCommand: Equatable, Sendable \{(.*?)\n\}", router, re.S).group(1)
        lines = [re.sub(r"\([^)]*\)", "", l.strip()[5:]) for l in body.splitlines() if l.strip().startswith("case ")]
        cases = [name.strip() for line in lines for name in line.split(",")]
        self.assertEqual(set(cases), {"dismiss", "refresh", "copyText", "openURL", "navigate", "routineOpen",
                                      "routineRunNow", "routinePause", "routineResume", "routineCreate", "routineSave"})
        for name in cases:
            self.assertFalse(ref.denied_surface(name), name)
        hosts = MAC_SOURCES["RoutineSDUIHosts.swift"]
        mapping = re.search(r"static func appCommand\(_ screen: SDUIScreen\) -> AppCommand\? \{(.*?)\n    \}", hosts, re.S)
        self.assertEqual(re.findall(r"case \.(\w+): \.(\w+)", mapping.group(1)),
                         [("routines", "routines"), ("skills", "skills"), ("settings", "settings")])
        self.assertIn("case .chat, .boxes, .updates: nil", mapping.group(1))
        for call in re.findall(r"await store\.(\w+)\(", hosts):
            self.assertIn(call, {"refreshRoutines", "runRoutineNow", "setRoutine", "createRoutine", "updateRoutine"})

    def test_four_wiring_cases_keep_the_compiled_views(self):
        hosts = MAC_SOURCES["RoutineSDUIHosts.swift"]
        self.assertIn("case .compiled: RoutineResultCard(message: message)", hosts)
        self.assertIn("case .compiled: RoutineEditorSheet(bot: bot, job: job)", hosts)
        self.assertEqual(hosts.count("case .updateRequired: SDUIUpdateRequiredView("), 2)
        message = (ROOT / "Sources/AgentApp/Views/MessageView.swift").read_text(encoding="utf-8")
        self.assertIn("case .routineResult: RoutineResultCardHost(message: message)", message)
        routines = (ROOT / "Sources/AgentApp/Views/RoutinesView.swift").read_text(encoding="utf-8")
        self.assertIn("RoutineEditorHost(bot: bot, job: target.job)", routines)
        self.assertIn("static let defaultValue = SDUIViewSource.compiledOnly", MAC_SOURCES["SDUIMacSource.swift"])
        source = CORE_SOURCES["SDUIViewSource.swift"]
        self.assertIn('if isViewKilled(view) { return .compiled(reason: "killed") }', source)
        self.assertIn('guard let data = documents[view] else { return .compiled(reason: "no_document") }', source)
        self.assertIn("case .fallback(let reason): return .compiled(reason: reason)", source)
        self.assertIn("case .updateRequired(let reason): return .updateRequired(reason: reason)", source)
        app_tests = (ROOT / "Tests/AgentAppTests/RoutineSDUITests.swift").read_text(encoding="utf-8")
        for case in ('"no bundle"', '"decoder fallback"', '"killed view"', "update == updateView"):
            self.assertIn(case, app_tests)

    def test_sources_under_500_lines_and_schemas_note(self):
        files = list(RENDER.glob("*.swift")) + list(MAC.glob("*.swift"))
        files += [TESTS / n for n in ("SDUIRenderTreeTests.swift", "SDUIActionRouterTests.swift", "SDUIViewSourceTests.swift")]
        files += [ROOT / "Tests/AgentAppTests/RoutineSDUITests.swift", Path(__file__),
                  ROOT / "scripts/release/ui_render.py", ROOT / "scripts/release/make_ui_renders.py"]
        for path in files:
            self.assertLessEqual(len(path.read_text(encoding="utf-8").splitlines()), 500, path.name)
        schemas = (ROOT / "docs/update-service/SCHEMAS.md").read_text(encoding="utf-8")
        self.assertIn("### P7b renderer", schemas)


if __name__ == "__main__":
    renders = sum(1 for c in VECTORS["cases"] if c["expect"]["verdict"] == "render")
    print(f"SDUI renders: {renders} golden documents, {len(make_ui_renders.TARGETS)} routine targets", flush=True)
    unittest.main()
