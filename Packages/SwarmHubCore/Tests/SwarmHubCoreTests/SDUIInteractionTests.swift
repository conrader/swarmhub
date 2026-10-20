import Foundation
import Testing
@testable import SwarmHubCore

/// P7c: the renderer state the Mac and iOS views share (`SDUIInteraction`), and the routine binding data both build.
@MainActor struct SDUIInteractionTests {
    let router = SDUIActionRouter(urlHosts: ["docs.swarmhub.test"])
    let flow = SDUIFlowPosition(key: "0.1", count: 3)

    func action(_ command: SDUICommand, _ argument: String? = nil, confirm: Bool = false) -> SDUIResolvedAction {
        SDUIResolvedAction(command: command, argument: argument, requiresConfirmation: command == .openURL || confirm)
    }

    func actions(offering offered: @escaping @MainActor (SDUIAppCommand) -> Bool = { _ in true }) -> SDUIActions {
        SDUIActions(router: router, isAvailable: offered, perform: { _ in nil })
    }

    @Test func flowMovesStayWithinTheStepsAndWaitForConfirmation() throws {
        var state = SDUIInteraction()
        let outcome1 = state.press(action(.flowBack), label: "Back", flow: flow, router: router)
        #expect(outcome1 == nil)
        #expect(state.step(flow) == 0)
        for _ in 0..<5 { _ = state.press(action(.flowNext), label: "Next", flow: flow, router: router) }
        #expect(state.step(flow) == 2)
        // confirm: true asks first; decline leaves the step, accept moves it.
        let outcome2 = state.press(action(.flowBack, confirm: true), label: "Back", flow: flow, router: router)
        #expect(outcome2 == nil)
        let pending = try #require(state.confirmation)
        #expect(pending.flow == flow)
        #expect(pending.request.title == "Back?")
        let outcome3 = state.resolve(pending, accepted: false)
        #expect(outcome3 == nil)
        #expect(state.confirmation == nil)
        #expect(state.step(flow) == 2)
        _ = state.press(action(.flowBack, confirm: true), label: "Back", flow: flow, router: router)
        let again = try #require(state.confirmation)
        let outcome4 = state.resolve(again, accepted: true)
        #expect(outcome4 == nil)
        #expect(state.step(flow) == 1)
        // A flow move with no flow does nothing.
        let outcome5 = state.press(action(.flowNext), label: "Next", flow: nil, router: router)
        #expect(outcome5 == nil)
        #expect(state.step(flow) == 1)
    }

    @Test func commandsRunOnlyAfterConfirmationAndOneAtATime() throws {
        var state = SDUIInteraction()
        let run = action(.routineRunNow, "job-42", confirm: true)
        let outcome6 = state.press(run, label: "Run now", flow: nil, router: router)
        #expect(outcome6 == nil)
        let pending = try #require(state.confirmation)
        let resolved = state.resolve(pending, accepted: true)
        let command = try #require(resolved)
        #expect(command == .routineRunNow("job-42"))
        let outcome7 = state.start(command, actions: actions())
        #expect(outcome7)
        #expect(state.busy)
        // A second command while one runs is not started.
        let pressed = state.press(action(.copyText, "x"), label: "Copy", flow: nil, router: router)
        let copy = try #require(pressed)
        let outcome8 = state.start(copy, actions: actions())
        #expect(!outcome8)
        state.finish(failure: "Server said no")
        #expect(!state.busy)
        #expect(state.failure == "Server said no")
        // The next press clears the failure; a command the sink no longer offers does not start.
        _ = state.press(action(.copyText, "x"), label: "Copy", flow: nil, router: router)
        #expect(state.failure == nil)
        let outcome9 = state.start(copy, actions: actions(offering: { _ in false }))
        #expect(!outcome9)
        #expect(!state.busy)
    }

    @Test func refusalsAndDismissedDialogsDoNothing() throws {
        var state = SDUIInteraction()
        let outcome10 = state.press(action(.openURL, "https://evil.example/"), label: "Help", flow: nil, router: router)
        #expect(outcome10 == nil)
        #expect(state.confirmation == nil)
        let outcome11 = state.press(action(.routineOpen, ""), label: "Open", flow: nil, router: router)
        #expect(outcome11 == nil)
        let outcome12 = state.press(action(.routineCreate), label: "Create", flow: nil, router: router)
        #expect(outcome12 == nil)
        _ = state.press(action(.openURL, "https://docs.swarmhub.test/x"), label: "Help", flow: nil, router: router)
        #expect(state.confirmation?.request.message == "https://docs.swarmhub.test/x")
        state.dismissConfirmation()
        #expect(state.confirmation == nil)
        #expect(state == SDUIInteraction())
    }

    @Test func availabilityMatchesWhatAPressWouldDo() {
        let none = actions(offering: { _ in false })
        #expect(SDUIInteraction.isAvailable(action(.flowNext), flow: flow, actions: none))
        #expect(!SDUIInteraction.isAvailable(action(.flowNext, confirm: true), flow: nil, actions: actions()))
        #expect(!SDUIInteraction.isAvailable(action(.routineOpen, ""), flow: nil, actions: actions()))
        #expect(!SDUIInteraction.isAvailable(action(.dismiss), flow: nil, actions: none))
        #expect(SDUIInteraction.isAvailable(action(.openURL, "https://docs.swarmhub.test/x"), flow: nil, actions: actions()))
        // A submit asks the sink about its routine path, never `route` (which refuses it outside a form).
        let saveOnly = actions(offering: { if case .routineSave("job-42", _) = $0 { true } else { false } })
        #expect(SDUIInteraction.isAvailable(action(.routineSave, "job-42"), flow: nil, actions: saveOnly))
        #expect(!SDUIInteraction.isAvailable(action(.routineCreate), flow: nil, actions: saveOnly))
    }

    @Test func formValuesAreKeptPerFormAndChecked() throws {
        let json = #"""
        {"schema":"swarmhub/ui/1","view":"v","root":{"type":"form","id":"f","fields":[
         {"id":"name","kind":"text","label":"Name","required":true,"max_length":5,"value":{"bind":"routine.name"}},
         {"id":"schedule","kind":"text","label":"Schedule","required":true,"value":{"bind":"routine.schedule"}}],
         "submit":{"label":"Save","action":{"command":"routine.save","routine":{"bind":"routine.id"}}}}}
        """#
        guard case .render(let document) = SDUIDecoder.decode(Data(json.utf8), view: "v") else {
            Issue.record("did not render")
            return
        }
        let data = SDUIData(["routine.id": .string("job-42"), "routine.name": .string("Daily"), "routine.schedule": .string("0 9 * * *")])
        var state = SDUIInteraction()
        guard case .form(let form)? = state.tree(document, data: data)?.element else {
            Issue.record("unexpected tree")
            return
        }
        #expect(state.value(form, "name") == .text("Daily"))
        #expect(state.problems(form).isEmpty)
        state.setValue(.text("Too long"), form: form, field: "name")
        #expect(state.value(form, "name") == .text("Too long"))
        #expect(state.problems(form) == (["name": "too_long"] as [String: String]))
        let outcome13 = state.submit(form, router: router)
        #expect(outcome13 == nil)
        state.setValue(.text("Night"), form: form, field: "name")
        let outcome14 = state.submit(form, router: router)
        #expect(outcome14 == .routineSave("job-42", SDUIRoutineDraft(name: "Night", schedule: "0 9 * * *", prompt: nil)))
    }

    @Test func routineDataUsesTheSharedBindingPaths() {
        let routine = SDUIRoutineFields(id: "job-42", name: "Morning report", prompt: "Summarise.", schedule: "0 9 * * 1-5",
                                        scheduleText: "Weekdays at 09:00", enabled: false, state: "paused", lastStatus: nil)
        let editor = SDUIRoutineTarget.editorData(profile: "Grok Bot", routine: routine)
        #expect(editor.values["routine.enabled"] == .bool(false))
        #expect(editor.values["routine.schedule_text"] == .string("Weekdays at 09:00"))
        #expect(editor.values["routine.last_status"] == nil)
        #expect(editor.values["profile.name"] == .string("Grok Bot"))
        #expect(SDUIRoutineTarget.editorData(profile: "Grok Bot", routine: nil).values.keys.sorted() == (["profile.name"] as [String]))
        let result = SDUIRoutineResultFields(routineName: "Renamed", routineID: "job-43", status: "error", failed: true,
                                             title: "Routine failed", ranText: "Ran 9:02", finishedAt: "Oct 20", hasOutput: false,
                                             summary: "", error: "timeout", note: nil)
        let card = SDUIRoutineTarget.cardData(result, profile: nil, routine: routine)
        #expect(card.values["routine.name"] == .string("Renamed"))
        #expect(card.values["routine.id"] == .string("job-43"))
        #expect(card.values["routine.prompt"] == .string("Summarise."))
        #expect(card.values["result.failed"] == .bool(true))
        #expect(card.values["result.error"] == .string("timeout"))
        #expect(card.values["result.summary"] == nil)
        #expect(card.values["result.note"] == nil)
        #expect(card.values["profile.name"] == nil)
    }
}
