import Foundation
import Testing
@testable import AgentApp

// uxfix3 (Konrad, 29 Oct): a steer Hermes refuses because its run no longer takes input (409 `run_not_accepting_steer`
// while a text-only answer finishes; live run 27 Oct) goes as the next message by itself, never a button to press.
// Never after the user's Stop: then it is only offered.

let finishingRun = BackendError.http(409, "Run is not currently accepting steer input: run_1 (run_not_accepting_steer)")

@MainActor @Test func aSteerTheFinishingRunRefusesGoesAsTheNextMessageByItself() async throws {
    let backend = ScriptedTurnBackend(steerFails: true, steerError: finishingRun)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "use metric"))
    let bubble = try #require(bot.messages.first { $0.content == "use metric" })
    try await waitUntil { bubble.metadata[SteerKey.steer] == "next" }
    #expect(!store.canSendAsNextMessage(bubble), "no button: it already waits as the next message")
    #expect(!bot.messages.contains { $0.metadata[TurnKey.tone] == "warning" }, "no technical warning line")
    #expect(store.anyTurnRunning && bot.messages[1].turnState == .incomplete, "the answer was not stopped")
    await backend.emit(.token("Done."), .completed); await backend.end(stream: 1)
    try await backend.calls.wait { $0.contains("send:use metric") }
    #expect(bubble.metadata[SteerKey.steer] == "sentNext")
    await backend.emit(.token("Metric."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(await backend.calls.all == ["send:go", "steer-failed:use metric", "send:use metric"], "sent once, after the answer; never a Stop")
    #expect(bot.messages.last?.content == "Metric.")
    #expect(store.errorMessage == nil)
}

@MainActor @Test func aSteerRefusedAfterTheUsersStopIsOfferedNotSent() async throws {
    let backend = ScriptedTurnBackend(steerFails: true, steerError: finishingRun)
    await backend.holdSteers()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "use metric"))
    try await backend.calls.wait { $0.contains("steer-held:use metric") }
    store.stop(); try await waitUntil { !store.anyTurnRunning }
    await backend.releaseSteers()
    let bubble = try #require(bot.messages.first { $0.content == "use metric" })
    try await waitUntil { bubble.metadata[SteerKey.steer] == "failed" }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!(await backend.calls.all.contains("send:use metric")), "Stop means stop: nothing goes by itself")
    #expect(store.canSendAsNextMessage(bubble), "Send as next message is offered")
}

@MainActor @Test func theUsersStopTakesBackASteerWaitingByItself() async throws {
    let backend = ScriptedTurnBackend(steerFails: true, steerError: finishingRun)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: true)
    #expect(store.send(text: "use metric"))
    let bubble = try #require(bot.messages.first { $0.content == "use metric" })
    try await waitUntil { bubble.metadata[SteerKey.steer] == "next" }
    store.stop(); try await waitUntil { !store.anyTurnRunning }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!(await backend.calls.all.contains("send:use metric")), "the queued text did not go after Stop")
    #expect(bubble.metadata[SteerKey.steer] == "failed" && store.canSendAsNextMessage(bubble), "offered instead")
    #expect(store.turns.nextMessages.isEmpty)
    // Pressed by the user after the Stop, it goes.
    #expect(store.sendAsNextMessage(bubble))
    try await backend.calls.wait { $0.contains("send:use metric") }
    await backend.end(); try await waitUntil { !store.anyTurnRunning }
}

@Test func whichSteerRefusalsMeanTheRunIsOver() {
    #expect(AppStore.runTakesNoSteer(finishingRun))
    #expect(AppStore.runTakesNoSteer(BackendError.http(409, "Run did not accept steer text: run_1 (steer_not_accepted)")))
    #expect(AppStore.runTakesNoSteer(BackendError.http(404, "Run not found: run_1 (run_not_found)")))
    #expect(AppStore.runTakesNoSteer(BackendError.unavailable(HermesBackend.noRunYet)))
    #expect(!AppStore.runTakesNoSteer(BackendError.http(500, "boom (steer_failed)")), "a broken box is shown, not hidden")
    #expect(!AppStore.runTakesNoSteer(BackendError.http(400, "Missing non-empty steer text (invalid_steer_input)")))
    #expect(!AppStore.runTakesNoSteer(URLError(.networkConnectionLost)))
}
