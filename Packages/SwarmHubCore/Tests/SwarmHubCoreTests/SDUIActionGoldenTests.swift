import Foundation
import Testing
@testable import SwarmHubCore

/// P7c action goldens (Tests/Fixtures/release-bundles/ui-render/actions/, written by scripts/release/make_ui_renders.py
/// from scripts/release/ui_actions.py): what every button and form submit of the shared golden documents does through
/// `SDUIActionRouter` and `SDUIInteraction`. The Mac and iOS renderers both draw from these, and this suite runs on
/// macOS (`swift test`) and on the iOS simulator (`scripts/test-ios-sdui.sh`), so confirmations, refusals and flow
/// moves are the same on both.
@MainActor struct SDUIActionGoldenTests {
    @Test func everyRenderGoldenActsAsStated() throws {
        let data = try SDUIRenderFixtures.context()
        let renders = try SDUIFixtures.catalog().cases.filter { $0.expect.verdict == "render" }
        #expect(renders.count >= 10)
        for vector in renders {
            guard case .render(let document) = SDUIFixtures.decode(SDUIFixtures.document(vector.inputs.document),
                                                                    vector.inputs) else {
                Issue.record("\(vector.id) did not render")
                continue
            }
            let router = SDUIActionRouter(urlHosts: Set(vector.inputs.urlHosts))
            #expect(Self.describe(document, data: data, router: router) == SDUIRenderFixtures.text("actions/\(vector.id).txt"),
                    "\(vector.id)")
        }
    }

    @Test func targetsAndEdgesActAsStated() throws {
        let data = try SDUIRenderFixtures.context()
        let router = SDUIActionRouter(urlHosts: [])
        var documents: [(String, Data, String)] = [
            ("targets/routine-result-card", SDUIRenderFixtures.target("routine-result-card"), SDUIRoutineTarget.resultCardView),
            ("targets/routine-edit-form", SDUIRenderFixtures.target("routine-edit-form"), SDUIRoutineTarget.editFormView),
            ("targets/routine-create-form", SDUIRenderFixtures.target("routine-create-form"), SDUIRoutineTarget.createFormView)
        ]
        let edges = SDUIRenderFixtures.directory.appendingPathComponent("actions/cases/edges.json")
        documents.append(("cases/edges", try Data(contentsOf: edges), "p7c_action_edges"))
        for (name, bytes, view) in documents {
            guard case .render(let document) = SDUIDecoder.decode(bytes, view: view) else {
                Issue.record("\(name) did not render")
                continue
            }
            #expect(Self.describe(document, data: data, router: router) == SDUIRenderFixtures.text("actions/\(name).txt"), "\(name)")
        }
    }

    /// The same text as `ui_actions.describe`: one line per button or submit in render-tree order, every flow step.
    static func describe(_ document: SDUIDocument, data: SDUIData, router: SDUIActionRouter) -> String {
        var lines: [String] = []
        if let root = SDUIRenderer.tree(document, data: data) { walk(root, flow: nil, router: router, into: &lines) }
        return (lines.isEmpty ? ["(none)"] : lines).joined(separator: "\n") + "\n"
    }

    static func walk(_ node: SDUIRenderNode, flow: SDUIFlowPosition?, router: SDUIActionRouter, into lines: inout [String]) {
        // A sink that offers every command: only refusals and flow moves outside a flow are unavailable.
        let everything = SDUIActions(router: router, isAvailable: { _ in true }, perform: { _ in nil })
        func yes(_ flag: Bool) -> String { flag ? "yes" : "no" }
        switch node.element {
        case .list(let children, _), .card(_, _, let children):
            for child in children { walk(child, flow: flow, router: router, into: &lines) }
        case .flow(_, let steps):
            let position = SDUIFlowPosition(key: node.key, count: steps.count)
            for step in steps {
                for child in step.children { walk(child, flow: position, router: router, into: &lines) }
            }
        case .button(let label, let action, _):
            let available = SDUIInteraction.isAvailable(action, flow: flow, actions: everything)
            lines.append("\(node.key) button \(quote(label)) available=\(yes(available)) press: "
                         + step(router.route(action, label: label)))
        case .form(let form):
            let head = "\(node.key) submit form=\(form.id) \(quote(form.submitLabel))"
            let available = SDUIInteraction.isAvailable(form.submit, flow: nil, actions: everything)
            lines.append("\(head) available=\(yes(available)) initial: " + step(router.submit(form, values: [:])))
            let blank = Dictionary(uniqueKeysWithValues: form.fields.filter { $0.kind != .toggle }.map { ($0.id, SDUIFieldValue.text("")) })
            lines.append("\(head) blank: " + step(router.submit(form, values: blank)))
        default:
            break
        }
    }

    static func step(_ step: SDUIActionRouter.Step) -> String {
        switch step {
        case .moveFlow(let delta): return "move_flow " + (delta > 0 ? "+1" : "-1")
        case .perform(let command): return "perform " + self.command(command)
        case .refused(let reason): return "refused " + reason
        case .confirm(let request):
            return "confirm title=\(quote(request.title)) button=\(quote(request.button)) message=\(quote(request.message)) "
                + "accept: \(self.step(request.resolve(accepted: true))) decline: \(self.step(request.resolve(accepted: false)))"
        }
    }

    static func command(_ command: SDUIAppCommand) -> String {
        switch command {
        case .dismiss: return "dismiss"
        case .refresh: return "refresh"
        case .copyText(let text): return "copy_text " + quote(text)
        case .openURL(let url): return "open_url " + quote(url.absoluteString)
        case .navigate(let screen): return "navigate " + screen.rawValue
        case .routineOpen(let id): return "routine.open " + quote(id)
        case .routineRunNow(let id): return "routine.run_now " + quote(id)
        case .routinePause(let id): return "routine.pause " + quote(id)
        case .routineResume(let id): return "routine.resume " + quote(id)
        case .routineCreate(let draft): return "routine.create " + self.draft(draft)
        case .routineSave(let id, let draft): return "routine.save \(quote(id)) " + self.draft(draft)
        }
    }

    static func draft(_ draft: SDUIRoutineDraft) -> String {
        "name=\(quote(draft.name)) schedule=\(quote(draft.schedule)) prompt=" + (draft.prompt.map(quote) ?? "none")
    }

    static func quote(_ text: String) -> String { SDUIRenderText.quote(text) }
}
