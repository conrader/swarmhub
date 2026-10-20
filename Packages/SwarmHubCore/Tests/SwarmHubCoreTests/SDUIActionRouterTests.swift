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
        #expect(confirmation.resolve(accepted: true) == .perform(.openURL(try #require(URL(string: url)))))
        #expect(confirmation.resolve(accepted: false) == .refused("confirmation_declined"))
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
        #expect(confirmation.resolve(accepted: true) == .perform(.routineRunNow("job-42")))
        #expect(confirmation.title == "Run now?")
    }

    @Test func flowMovesWaitForConfirmation() throws {
        for (command, delta, label) in [(SDUICommand.flowNext, 1, "Next"), (.flowBack, -1, "Back")] {
            #expect(router.route(action(command), label: label) == .moveFlow(delta))
            var index = 1
            func apply(_ step: SDUIActionRouter.Step) {
                if case .moveFlow(let delta) = step { index += delta }
            }
            let step = router.route(action(command, confirm: true), label: label)
            apply(step)
            #expect(index == 1, "asking must leave the current step unchanged")
            guard case .confirm(let pending) = step else {
                Issue.record("flow move skipped confirmation")
                continue
            }
            #expect(pending.title == label + "?")
            #expect(pending.button == label)
            #expect(pending.message.isEmpty)
            #expect(pending.resolve(accepted: false) == .refused("confirmation_declined"))
            apply(pending.resolve(accepted: false))
            #expect(index == 1, "declining must leave the current step unchanged")
            #expect(pending.resolve(accepted: true) == .moveFlow(delta))
            apply(pending.resolve(accepted: true))
            #expect(index == 1 + delta)
        }
    }

    @Test func everyLocalCommandHonorsConfirmation() {
        let cases: [(SDUICommand, String?, SDUIAppCommand)] = [
            (.dismiss, nil, .dismiss), (.refresh, nil, .refresh), (.copyText, "hello", .copyText("hello")),
            (.navigate, "routines", .navigate(.routines)), (.routineOpen, "job-42", .routineOpen("job-42")),
            (.routineRunNow, "job-42", .routineRunNow("job-42")), (.routinePause, "job-42", .routinePause("job-42")),
            (.routineResume, "job-42", .routineResume("job-42"))
        ]
        for (command, argument, expected) in cases {
            #expect(router.route(action(command, argument), label: "Do") == .perform(expected))
            guard case .confirm(let pending) = router.route(action(command, argument, confirm: true), label: "Do") else {
                Issue.record("\(command) skipped confirmation")
                continue
            }
            #expect(pending.resolve(accepted: false) == .refused("confirmation_declined"))
            #expect(pending.resolve(accepted: true) == .perform(expected))
        }
        // Invalid actions still refuse before asking; confirmation cannot make them valid.
        #expect(router.route(action(.navigate, "unknown", confirm: true), label: "Do") == .refused("unknown_screen"))
        #expect(router.route(action(.openURL, "https://evil.example/", confirm: true), label: "Do") == .refused("url_not_allowed"))
        #expect(router.route(action(.routineOpen, "", confirm: true), label: "Do") == .refused("routine_unavailable"))
        for command in [SDUICommand.routineCreate, .routineSave] {
            #expect(router.route(action(command, "job-42", confirm: true), label: "Do") == .refused("submit_outside_form"))
        }
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

    @Test func formSubmitsWaitForConfirmationAfterValidation() throws {
        let original = try editForm()
        for command in [SDUICommand.routineCreate, .routineSave] {
            let form = SDUIRenderForm(id: original.id, title: nil, fields: original.fields, initial: original.initial,
                                      submitLabel: "Submit", submit: action(command, "job-42", confirm: true))
            let draft = try #require(SDUIRoutineTarget.draft(form.initial))
            let expected: SDUIAppCommand = command == .routineCreate ? .routineCreate(draft) : .routineSave("job-42", draft)
            guard case .confirm(let pending) = router.submit(form, values: [:]) else {
                Issue.record("form submit skipped confirmation")
                continue
            }
            #expect(pending.title == "Submit?")
            #expect(pending.resolve(accepted: false) == .refused("confirmation_declined"))
            #expect(pending.resolve(accepted: true) == .perform(expected))
            #expect(router.submit(form, values: ["name": .text("")]) == .refused("required"))
            #expect(router.submit(form, values: ["prompt": .text(String(repeating: "p", count: 5001))]) == .refused("invalid_form"))
        }
    }

    @Test func draftUsesTheCompiledEditorLimits() {
        #expect(SDUIRoutineTarget.draft(["name": .text("a"), "schedule": .text("")]) == nil)
        #expect(SDUIRoutineTarget.draft(["name": .text(String(repeating: "é", count: 200)), "schedule": .text("0 9 * * *")])?
            .prompt == nil)
        #expect(SDUIRoutineTarget.draft(["name": .text(String(repeating: "é", count: 201)), "schedule": .text("0 9 * * *")]) == nil)
    }
}
