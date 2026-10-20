import Foundation
import Testing
@testable import SwarmHubCore

struct SDUIActionRouterTests {
    let router = SDUIActionRouter(urlHosts: ["docs.swarmhub.test"])

    func action(_ command: SDUICommand, _ argument: String? = nil, confirm: Bool = false) -> SDUIResolvedAction {
        SDUIResolvedAction(command: command, argument: argument, requiresConfirmation: command == .openURL || confirm)
    }

    @Test func openURLAlwaysAsksAndOnlyForAllowlistedHosts() throws {
        let url = "https://docs.swarmhub.test/routines?from=card"
        guard case .confirm(let confirmation) = router.route(action(.openURL, url), label: "Help") else {
            Issue.record("open_url did not ask first")
            return
        }
        #expect(confirmation.command == .openURL(try #require(URL(string: url))))
        #expect(confirmation.message == url)
        // Even an action that claims no confirmation is needed asks (the router never reads `confirm` for URLs).
        let unconfirmed = SDUIResolvedAction(command: .openURL, argument: url, requiresConfirmation: false)
        guard case .confirm = router.route(unconfirmed, label: "Help") else {
            Issue.record("open_url skipped the confirmation")
            return
        }
        for refused in ["https://evil.example/x", "http://docs.swarmhub.test/", "https://docs.swarmhub.test.evil.example/",
                        "https://user@docs.swarmhub.test/", "https://docs.swarmhub.test:444/", "javascript:alert(1)",
                        "https://docs.swarmhub.test/#frag", "https://DOCS.swarmhub.test/", ""] {
            #expect(router.route(action(.openURL, refused), label: "Help") == .refused("url_not_allowed"), "\(refused)")
        }
        #expect(SDUIActionRouter(urlHosts: []).route(action(.openURL, url), label: "Help") == .refused("url_not_allowed"))
    }

    @Test func localCommandsMapToTheClosedAppCommands() {
        #expect(router.route(action(.flowNext), label: "Next") == .moveFlow(1))
        #expect(router.route(action(.flowBack), label: "Back") == .moveFlow(-1))
        #expect(router.route(action(.dismiss), label: "Close") == .perform(.dismiss))
        #expect(router.route(action(.refresh), label: "Check") == .perform(.refresh))
        #expect(router.route(action(.copyText, "hello"), label: "Copy") == .perform(.copyText("hello")))
        #expect(router.route(action(.navigate, "routines"), label: "Open") == .perform(.navigate(.routines)))
        #expect(router.route(action(.navigate, "operation_review"), label: "Open") == .refused("unknown_screen"))
        #expect(router.route(action(.routinePause, "job-42"), label: "Pause") == .perform(.routinePause("job-42")))
        #expect(router.route(action(.routineResume, "job-42"), label: "Resume") == .perform(.routineResume("job-42")))
        #expect(router.route(action(.routineOpen, "job-42"), label: "Open") == .perform(.routineOpen("job-42")))
        #expect(router.route(action(.routineRunNow, ""), label: "Run") == .refused("routine_unavailable"))
        #expect(router.route(action(.routineCreate), label: "Create") == .refused("submit_outside_form"))
        #expect(router.route(action(.routineSave, "job-42"), label: "Save") == .refused("submit_outside_form"))
        guard case .confirm(let confirmation) = router.route(action(.routineRunNow, "job-42", confirm: true), label: "Run now")
        else {
            Issue.record("confirm: true did not ask")
            return
        }
        #expect(confirmation.command == .routineRunNow("job-42"))
        #expect(confirmation.title == "Run now?")
    }

    func editForm() throws -> SDUIRenderForm {
        let data = try SDUIRenderFixtures.context()
        guard case .render(let document) = SDUIDecoder.decode(SDUIRenderFixtures.target("routine-edit-form"),
                                                              view: SDUIRoutineTarget.editFormView),
              case .card(_, _, let children)? = SDUIRenderer.tree(document, data: data)?.element,
              case .form(let form)? = children.first?.element else { throw TestStop() }
        return form
    }

    @Test func submitMapsOnlyToTheRoutinePaths() throws {
        let form = try editForm()
        let saved = SDUIRoutineDraft(name: "Morning report", schedule: "0 9 * * 1-5",
                                     prompt: "Summarise yesterday's commits.\nKeep it short.")
        #expect(router.submit(form, values: [:]) == .perform(.routineSave("job-42", saved)))
        let edited = router.submit(form, values: ["name": .text("  Evening  "), "schedule": .text(" every 2h ")])
        #expect(edited == .perform(.routineSave("job-42", SDUIRoutineDraft(name: "Evening", schedule: "every 2h",
                                                                              prompt: saved.prompt))))
        #expect(router.submit(form, values: ["name": .text("   ")]) == .refused("required"))
        #expect(router.submit(form, values: ["name": .text(String(repeating: "n", count: 201))]) == .refused("too_long"))
        #expect(router.submit(form, values: ["prompt": .text(String(repeating: "p", count: 5001))]) == .refused("invalid_form"))
        let create = SDUIRenderForm(id: form.id, title: nil, fields: form.fields, initial: form.initial, submitLabel: "Create",
                                    submit: SDUIResolvedAction(command: .routineCreate, argument: nil, requiresConfirmation: false))
        #expect(router.submit(create, values: [:]) == .perform(.routineCreate(saved)))
        let notSubmit = SDUIRenderForm(id: form.id, title: nil, fields: form.fields, initial: form.initial, submitLabel: "X",
                                       submit: SDUIResolvedAction(command: .refresh, argument: nil, requiresConfirmation: false))
        #expect(router.submit(notSubmit, values: [:]) == .refused("not_a_submit"))
    }

    @Test func draftUsesTheCompiledEditorLimits() {
        #expect(SDUIRoutineTarget.draft(["name": .text("a"), "schedule": .text("")]) == nil)
        #expect(SDUIRoutineTarget.draft(["name": .text(String(repeating: "é", count: 200)), "schedule": .text("0 9 * * *")])?
            .prompt == nil)
        #expect(SDUIRoutineTarget.draft(["name": .text(String(repeating: "é", count: 201)), "schedule": .text("0 9 * * *")]) == nil)
    }
}
