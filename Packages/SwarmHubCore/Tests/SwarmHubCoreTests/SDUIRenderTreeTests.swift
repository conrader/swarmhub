import Foundation
import Testing
@testable import SwarmHubCore

/// P7b render goldens (Tests/Fixtures/release-bundles/ui-render/, written by scripts/release/make_ui_renders.py from
/// scripts/release/ui_render.py). SwarmHubCore runs on macOS and iOS, so P7c asserts parity by running this suite.
enum SDUIRenderFixtures {
    // Also read by scripts/test_swift_ui_render.py.
    static let renderFixture = "Tests/Fixtures/release-bundles/ui-render"
    static var directory: URL { UpdateVerifierTests.repository.appendingPathComponent(renderFixture) }

    static func text(_ name: String) -> String? {
        (try? Data(contentsOf: directory.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// context.json: binding path → string, integer or boolean.
    static func context() throws -> SDUIData {
        let value = try JCS.parse(Data(contentsOf: directory.appendingPathComponent("context.json")))
        guard case .object(let members) = value else { throw TestStop() }
        var values: [String: SDUIDataValue] = [:]
        for (path, member) in members {
            switch member {
            case .string(let text): values[path] = .string(text)
            case .integer(let number): values[path] = .integer(number)
            case .bool(let flag): values[path] = .bool(flag)
            default: throw TestStop()
            }
        }
        return SDUIData(values)
    }

    static func target(_ name: String) -> Data {
        (try? Data(contentsOf: directory.appendingPathComponent("targets/\(name).json"))) ?? Data()
    }
}

struct SDUIRenderTreeTests {
    @Test func everyRenderGoldenMatches() throws {
        let data = try SDUIRenderFixtures.context()
        let renders = try SDUIFixtures.catalog().cases.filter { $0.expect.verdict == "render" }
        #expect(renders.count >= 10)
        for vector in renders {
            guard case .render(let document) = SDUIFixtures.decode(SDUIFixtures.document(vector.inputs.document),
                                                                    vector.inputs) else {
                Issue.record("\(vector.id) did not render")
                continue
            }
            let text = SDUIRenderText.describe(SDUIRenderer.tree(document, data: data))
            #expect(text == SDUIRenderFixtures.text(vector.id + ".txt"), "\(vector.id)")
        }
    }

    @Test func everyTargetGoldenMatches() throws {
        let data = try SDUIRenderFixtures.context()
        for (name, view) in [("routine-result-card", SDUIRoutineTarget.resultCardView),
                             ("routine-edit-form", SDUIRoutineTarget.editFormView),
                             ("routine-create-form", SDUIRoutineTarget.createFormView)] {
            // The Mac's compiled allowlist is empty; the targets must still render.
            guard case .render(let document) = SDUIDecoder.decode(SDUIRenderFixtures.target(name), view: view) else {
                Issue.record("\(name) did not render")
                continue
            }
            let text = SDUIRenderText.describe(SDUIRenderer.tree(document, data: data))
            #expect(text == SDUIRenderFixtures.text("targets/\(name).txt"), "\(name)")
        }
    }

    @Test func deniedPathsNeverReachTheTree() throws {
        let data = try SDUIRenderFixtures.context()
        #expect(data.values["result.api_key"] == nil)
        #expect(data.values["routine.name"] == .string("Morning report"))
        #expect(SDUIData(["record.session_id": .string("x"), "box.device_id": .string("y")]).values.isEmpty)
    }

    @Test func markdownKeepsStylingButNeverLinks() {
        for source in ["See [docs](https://example.com)", "<https://example.com>", "https://example.com plain",
                       "mail <a@b.example>", "![img](https://example.com/x.png)", "[ref]\n\n[ref]: https://example.com"] {
            let styled = SDUIRenderText.inline(source)
            #expect(!SDUIRenderText.hasLinks(styled), "\(source)")
        }
        let bold = SDUIRenderText.inline("All **3** checks")
        #expect(String(bold.characters) == "All 3 checks")
        #expect(bold.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func quotingEscapesControlsOnly() {
        #expect(SDUIRenderText.quote("a\"b\\c\n\t\r\u{1b}é\u{FEFF}") == "\"a\\\"b\\\\c\\n\\t\\r\\u001bé\u{FEFF}\"")
    }

    @Test func hiddenNodesFieldsAndRootAreLeftOut() throws {
        let json = #"""
        {"schema":"swarmhub/ui/1","view":"v","root":{"type":"card","children":[
         {"type":"text","text":"gone","visible_if":{"exists":{"bind":"result.missing"}}},
         {"type":"form","id":"f","fields":[
          {"id":"box","kind":"choice","label":"Box","options":[{"value":"local","label":"Here"},{"value":"far","label":"There"}],
           "value":{"bind":"routine.box"}},
          {"id":"host_note","kind":"text","label":"Remote note","visible_if":{"equals":{"bind":"form.box","value":"far"}}}],
          "submit":{"label":"Go","action":{"command":"routine.create"}}}]}}
        """#
        guard case .render(let document) = SDUIDecoder.decode(Data(json.utf8), view: "v") else {
            Issue.record("did not render")
            return
        }
        let local = SDUIData(["routine.box": .string("local")])
        guard case .card(_, _, let children)? = SDUIRenderer.tree(document, data: local)?.element,
              case .form(let form)? = children.first?.element else {
            Issue.record("unexpected tree")
            return
        }
        #expect(children.count == 1)
        #expect(form.fields.map(\.id) == (["box"] as [String]))
        #expect(form.initial["box"] == .text("local"))
        // Current form values drive `form.*` predicates on every render.
        let far = SDUIRenderer.tree(document, data: local, forms: ["f": ["box": .text("far")]])
        guard case .card(_, _, let farChildren)? = far?.element, case .form(let farForm)? = farChildren.first?.element else {
            Issue.record("unexpected tree")
            return
        }
        #expect(farForm.fields.map(\.id) == (["box", "host_note"] as [String]))
        // A bound value that is not an option starts empty.
        let unknown = SDUIRenderer.initialValues(try #require(fields(document)), data: SDUIData(["routine.box": .string("x")]))
        #expect(unknown["box"] == .text(""))
        let hidden = Data(#"{"schema":"swarmhub/ui/1","view":"v","root":{"type":"text","text":"x","visible_if":{"exists":{"bind":"app.flag"}}}}"#.utf8)
        guard case .render(let hiddenDocument) = SDUIDecoder.decode(hidden, view: "v") else {
            Issue.record("did not render")
            return
        }
        #expect(SDUIRenderText.describe(SDUIRenderer.tree(hiddenDocument, data: SDUIData())) == "(hidden)\n")
    }

    func fields(_ document: SDUIDocument) -> [SDUIField]? {
        guard case .card(_, _, let children) = document.root.component, case .form(_, let fields, _)? = children.last?.component
        else { return nil }
        return fields
    }

    @Test func progressAndDiffDefaults() throws {
        let json = #"""
        {"schema":"swarmhub/ui/1","view":"v","root":{"type":"list","children":[
         {"type":"progress","value":{"bind":"result.done"}},{"type":"progress"},
         {"type":"diff_preview","text":{"bind":"result.diff"},"max_lines":2}]}}
        """#
        guard case .render(let document) = SDUIDecoder.decode(Data(json.utf8), view: "v") else {
            Issue.record("did not render")
            return
        }
        let data = SDUIData(["result.done": .integer(-4), "result.diff": .string("a\r\nb\nc")])
        #expect(SDUIRenderText.describe(SDUIRenderer.tree(document, data: data)) == """
        list style=plain
          progress total=100 value=0
          progress total=100 value=none
          diff_preview lines=2/3
            "a\\r"
            "b"

        """)
    }
}
