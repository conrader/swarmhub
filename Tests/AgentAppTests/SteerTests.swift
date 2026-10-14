import Foundation
import Testing
@testable import AgentApp

// P28: steer that actually lands. D1 route choice, Stop and send, the Stop-failure fallback, bubble copy, D5 order on
// screen (store, reload, history, sidebar) and the box handing a steer back. Synthetic backends only.

// MARK: D1 route

@Test func theRouteFollowsWhatTheTurnIsDoing() {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    var activity = ToolActivity()
    #expect(SteerRoute.choose(activity: nil) == .stopAndSend, "text only (or thinking): no tool batch will come")
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "c1"), at: at)
    #expect(SteerRoute.choose(activity: activity) == .queued, "a running step: the steer lands after it")
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "c1"), at: at)
    #expect(SteerRoute.choose(activity: activity) == .stopAndSend, "steps that all ended are not running")
    activity.apply(ToolEvent(phase: .started, name: "_thinking"), at: at)
    #expect(SteerRoute.choose(activity: activity) == .stopAndSend, "internal tools are not steps")
}

@Test func bubbleCopyPerPath() {
    func caption(_ metadata: [String: String]) -> String? { SteerCopy.caption(ChatMessage(role: .user, content: "x", metadata: metadata)) }
    #expect(caption([:]) == nil)
    #expect(caption(["steer": "sent"]) == "Sending…")
    #expect(caption(["steer": "queued"]) == "Delivered after the current step")
    #expect(caption(["steer": "delivered"]) == "Delivered")
    #expect(caption(["steer": "failed"]) == "Steer not delivered")
    #expect(caption(["correction": "stopping"]) == "Stopping the answer…")
    #expect(caption(["correction": "stopped"]) == "Stopped the answer and sent your correction")
    #expect(caption(["correction": "followup"]) == "Sent after the answer finished")
    #expect(SteerCopy.placeholder == "Add to this answer…")
    #expect(SteerCopy.hint == "Corrections land after the current step, or stop the answer and continue.")
}

// MARK: Stop and send

@MainActor @Test func steeringTextStopsTheAnswerThenSendsTheCorrection() async throws {
    let backend = ScriptedTurnBackend()
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: defaults)
    let bot = Bot(name: "Steer", backend: .hermes, hermesProfile: "default", hermesSessionID: "session-steer"); store.bots = [bot]; store.selectedBot = bot
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.steerHint == nil)
    #expect(store.send(text: " use metric "))
    #expect(store.steerHint == SteerCopy.hint, "the first steer shows the one-time caption")
    let lead = "send:\(SteerCopy.lead)\nuse metric"
    try await backend.calls.wait { $0.contains(lead) }
    let calls = await backend.calls.all
    #expect(calls == ["send:go", "stop:run-1", lead], "Stop is requested before the correction is sent")
    #expect(bot.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    let (partial, bubble) = (bot.messages[1], bot.messages[2])
    #expect(partial.content == "Before. " && partial.turnState == .stopped && !partial.isStreaming, "the partial stays, marked stopped")
    #expect(bubble.content == "use metric" && bubble.isCorrection && !bubble.isSteer, "the lead line is only in the sent text")
    #expect(SteerCopy.caption(bubble) == "Stopped the answer and sent your correction")
    #expect(bubble.outgoingText == SteerCopy.lead + "\nuse metric")
    #expect(!bot.messages.contains { $0.role == .system }, "no extra Stop line between the partial and the correction")
    // The correction's turn answers below it.
    await backend.emit(.token("Metric it is."), .completed); await backend.end()
    try await waitUntil { store.isIdle }
    #expect(bot.messages.last?.content == "Metric it is." && bot.messages.last?.turnState == .finished)
    // A later plain send clears the caption; it is shown once per install.
    #expect(store.send(text: "thanks")); #expect(store.steerHint == nil)
    store.stop(); try await waitUntil { store.isIdle }
}

@MainActor @Test func aFailedStopFallsBackToTheQueuedSteerAndSaysSo() async throws {
    let backend = ScriptedTurnBackend(stopFails: true)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "shorter"))
    try await backend.calls.wait { $0.contains("steer:shorter") }
    #expect(await backend.calls.all == ["send:go", "stop-failed", "steer:shorter"])
    try await waitUntil { bot.messages.contains { $0.metadata["steer"] == "queued" } }
    let bubble = try #require(bot.messages.first { $0.content == "shorter" })
    #expect(bubble.isSteer && !bubble.isCorrection && SteerCopy.caption(bubble) == "Delivered after the current step")
    #expect(bot.messages.contains { $0.role == .system && $0.content == SteerCopy.stopFailed })
    #expect(store.isStreaming && bot.messages[1].turnState == .incomplete, "the answer keeps streaming")
    store.stop(); try await waitUntil { store.isIdle }
}

// MARK: D5 order on screen

@MainActor @Test func aSteerDeliveredMidReplyContinuesInANewRowBelowIt() async throws {
    let url = temporaryStore()
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend, url: url)
    try await startSteerableTurn(store, backend, running: true)
    #expect(store.send(text: "use metric"))
    try await backend.calls.wait { $0.contains("steer:use metric") }
    try await waitUntil { bot.messages.last?.metadata["steer"] == "queued" }
    await backend.emit(.token("still before. "), step(.completed), .token("After."), step(.started, id: "c2"), step(.completed, id: "c2"), .completed)
    await backend.end()
    try await waitUntil { store.isIdle }

    let rows = bot.messages
    #expect(rows.map(\.role) == [.user, .assistant, .user, .assistant], "[user, assistant(part before), steer, assistant(rest)]")
    #expect(rows[1].content == "Before. still before. " && rows[1].metadata[TurnKey.part] == "1" && rows[1].turnState == .finished)
    #expect(rows[2].isSteer && rows[2].metadata["steer"] == "delivered" && SteerCopy.caption(rows[2]) == "Delivered")
    #expect(rows[3].content == "After." && rows[3].metadata[TurnKey.part] == "2" && rows[3].turnState == .finished && !rows[3].isStreaming)
    #expect(rows[1].activity?.total == 1 && rows[3].activity?.total == 1, "steps after delivery land on the new row")
    #expect(SidebarFragment.text(messages: rows, draft: nil, isWorking: false, archiveNewest: nil) == "After.")

    let reloaded = try #require(AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults()).bots.first)
    #expect(reloaded.messages.map(\.content) == ["go", "Before. still before. ", "use metric", "After."])
    #expect(reloaded.messages.map { $0.metadata[TurnKey.part] } == [nil, "1", nil, "2"])

    // The box keeps the steer as its own user row: a reconcile pass pairs both parts and adds nothing.
    let server = [srow("user", "go"), srow("assistant", "Before. still before. ", finish: "stop"), srow("user", "use metric"), srow("assistant", "After.", finish: "stop")]
    let plan = HistoryReconciler.plan(.init(local: rows.map(HistoryReconciler.LocalRow.init), server: server, mode: .chat(additions: true)))
    #expect(plan.additions.isEmpty && plan.edits.isEmpty && !plan.diverged && plan.counts.paired == 2)
}

@MainActor @Test func aCutSecondPartIsExtendedFromTheBoxInPlace() {
    var local = [lrow(.user, "go"), lrow(.assistant, "Before.", state: .finished), lrow(.user, "use metric", steer: true), lrow(.assistant, "Aft", state: .incomplete)]
    local[1].metadata[TurnKey.part] = "1"; local[2].metadata["steer"] = "delivered"; local[3].metadata[TurnKey.part] = "2"
    let server = [srow("user", "go"), srow("assistant", "Before.", finish: "stop"), srow("user", "use metric"), srow("assistant", "After the steer.", finish: "stop")]
    let plan = HistoryReconciler.plan(.init(local: local, server: server, mode: .chat(additions: true)))
    #expect(plan.additions.isEmpty)
    let result = applied(plan, to: local)
    #expect(result.map(\.text) == ["go", "Before.", "use metric", "After the steer."] && result[3].state == .finished)
    // An older steer bubble (no part after it) stays outside the turns, as before P28.
    var old = [lrow(.user, "go"), lrow(.assistant, "Whole answer", state: .finished), lrow(.user, "use metric", steer: true)]
    old[2].metadata["steer"] = "delivered"
    let oldPlan = HistoryReconciler.plan(.init(local: old, server: [srow("user", "go"), srow("assistant", "Whole answer", finish: "stop"), srow("user", "use metric"), srow("assistant", "More", finish: "stop")], mode: .chat(additions: true)))
    #expect(oldPlan.additions.isEmpty, "the box's steer turn is a duplicate of the local bubble")
}

// MARK: A steer the box hands back

@MainActor @Test func aSteerTheBoxHandsBackIsSentAsTheNextMessage() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: true)
    #expect(store.send(text: "use metric"))
    try await waitUntil { bot.messages.last?.metadata["steer"] == "queued" }
    // The last step ends, the model writes its final text, and the box returns the steer unread (`pending_steer`).
    await backend.emit(step(.completed), .steer(.returned("use metric")), .completed); await backend.end()
    let followUp = "send:\(SteerCopy.lead)\nuse metric"
    try await backend.calls.wait { $0.contains(followUp) }
    let bubble = try #require(bot.messages.first { $0.content == "use metric" })
    #expect(bubble.isCorrection && !bubble.isSteer && SteerCopy.caption(bubble) == "Sent after the answer finished")
    #expect(bot.messages.last?.role == .assistant && bot.messages.last?.isStreaming == true)
    store.stop(); try await waitUntil { store.isIdle }
}

// MARK: Groups

@MainActor @Test func aGroupSteerIsQueuedAndTheMemberContinuesBelowIt() async throws {
    let backend = ScriptedTurnBackend()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let dmt = Bot(name: "DMT", backend: .hermes, hermesProfile: "default"), achilles = Bot(name: "Achilles", backend: .hermes, hermesProfile: "default")
    store.bots = [dmt, achilles]
    let group = try #require(store.createGroup(name: "Pair", memberIDs: [dmt.id, achilles.id]))
    #expect(store.send(text: "@DMT hello", to: group))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:") } }
    await backend.emit(.token("Before. "))
    try await waitUntil { store.steerAvailable && store.streamingAssistant?.content == "Before. " }
    // No step runs, but Stop would end the round: a group steer is always queued.
    #expect(store.send(text: "shorter", to: group))
    try await waitUntil { group.messages.last?.metadata["steer"] == "queued" }
    await backend.emit(step(.started), step(.completed), .token("After."), .completed); await backend.end()
    try await waitUntil { store.isIdle }
    let rows = group.messages.filter { $0.role != .system }
    #expect(rows.map(\.content) == ["@DMT hello", "Before. ", "shorter", "After."])
    #expect(rows[3].authorID == dmt.id && rows[3].metadata[TurnKey.part] == "2" && rows[3].metadata[TurnKey.forUser] == rows[0].id.uuidString)
    #expect(await backend.calls.all.filter { $0.hasPrefix("stop") }.isEmpty)
}
