import Foundation
import Testing
@testable import AgentApp

// P28: steer that actually lands. uxfix1: a message typed during a turn never stops it: it steers the turn, or waits and
// goes when the turn ends (no steer on the runtime, attachments). Bubble copy, D5 order on screen (store, reload, history,
// sidebar) and the box handing a steer back. Synthetic backends only.

@Test func bubbleCopyPerPath() {
    func caption(_ metadata: [String: String]) -> String? { SteerCopy.caption(ChatMessage(role: .user, content: "x", metadata: metadata)) }
    #expect(caption([:]) == nil)
    #expect(caption(["steer": "sent"]) == "Sending…")
    #expect(caption(["steer": "queued"]) == "Delivered after the current step")
    #expect(caption(["steer": "delivered"]) == "Delivered")
    #expect(caption(["steer": "failed"]) == "Not delivered")
    #expect(SteerCopy.endedFirst == "The answer ended first.", "the line under a failed steer gives only the reason")
    // Rows saved before uxfix1 still read as they did.
    #expect(caption(["correction": "stopping"]) == "Stopping the answer…")
    #expect(caption(["correction": "stopped"]) == "Stopped the answer and sent your correction")
    #expect(caption(["correction": "followup"]) == "Sent after the answer finished")
    #expect(SteerCopy.placeholder == "Add to this answer…")
    #expect(SteerCopy.hint == "Your message goes into this answer without stopping it. If the answer ends first, it is sent as your next message.")
}

// MARK: Steer, never stop (uxfix1)

@MainActor @Test func withoutSteerAMessageWaitsAndGoesWhenTheAnswerEnds() async throws {
    let backend = ScriptedTurnBackend(steerless: true)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(!store.canSteer(in: bot))
    #expect(store.send(text: "and then this"), "sending during the turn is accepted, not refused")
    let waiting = try #require(bot.messages.first { $0.content == "and then this" })
    #expect(waiting.metadata[TurnWaitCopy.key] == "waiting" && store.hasWaitingTurn(in: bot))
    #expect(bot.messages.contains { $0.role == .system && $0.content == SteerCopy.afterTurn })
    #expect(await backend.calls.all == ["send:go"], "nothing is steered or stopped")
    #expect(bot.messages[1].turnState == .incomplete && bot.messages[1].isStreaming, "the answer keeps streaming")
    await backend.emit(.token("Done."), .completed); await backend.end()
    try await backend.calls.wait { $0.contains("send:and then this") }
    #expect(bot.messages[1].content == "Before. Done." && bot.messages[1].turnState == .finished, "the first answer finished whole")
    #expect(waiting.metadata[TurnWaitCopy.key] == nil && !bot.messages.contains { $0.content == SteerCopy.afterTurn }, "the wait line goes")
    await backend.emit(.token("Second."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.messages.filter { $0.role == .assistant }.map(\.content) == ["Before. Done.", "Second."])
    #expect(await backend.calls.all.filter { $0.hasPrefix("stop") || $0.hasPrefix("steer") }.isEmpty)
}

@MainActor @Test func anAttachmentTypedDuringATurnWaitsForItInsteadOfBeingRefused() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: true)
    let file = ChatAttachment(id: UUID(), kind: .text, name: "notes.txt", mimeType: "text/plain", byteCount: 5, text: "notes")
    #expect(store.send(text: "see this", attachments: [file]))
    #expect(store.errorMessage == nil, "no alert")
    let waiting = try #require(bot.messages.first { $0.content == "see this" })
    #expect(waiting.attachments.map(\.name) == ["notes.txt"] && waiting.metadata[TurnWaitCopy.key] == "waiting")
    #expect(await backend.calls.all == ["send:go"])
    await backend.emit(step(.completed), .token("Done."), .completed); await backend.end()
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:") && $0.contains("see this") } }
    store.stop(); try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func aFailedSteerKeepsTheAnswerRunning() async throws {
    let backend = ScriptedTurnBackend(steerFails: true)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "shorter"))
    try await waitUntil { bot.messages.contains { $0.metadata["steer"] == "failed" } }
    #expect(await backend.calls.all == ["send:go", "steer-failed:shorter"], "no Stop")
    let bubble = try #require(bot.messages.first { $0.content == "shorter" })
    #expect(store.canSendAsNextMessage(bubble), "Send as next message is offered")
    #expect(store.anyTurnRunning && bot.messages[1].turnState == .incomplete, "the answer keeps streaming")
    store.stop(); try await waitUntil { !store.anyTurnRunning }
}

// MARK: D5 order on screen

// MARK: A steer the box hands back

// MARK: Groups

@MainActor @Test func aGroupSteerIsQueuedAndTheMemberContinuesBelowIt() async throws {
    let backend = ScriptedTurnBackend()
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let dmt = Bot(name: "DMT", backend: .herdr), achilles = Bot(name: "Achilles", backend: .herdr)
    store.bots = [dmt, achilles]
    let group = try #require(store.createGroup(name: "Pair", memberIDs: [dmt.id, achilles.id]))
    #expect(store.send(text: "@DMT hello", to: group))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:") } }
    await backend.emit(.token("Before. "))
    try await waitUntil { (store.soleTurn?.steerAvailable == true) && store.soleTurn?.assistant?.content == "Before. " }
    // No step runs, but Stop would end the round: a group steer is always queued.
    #expect(store.send(text: "shorter", to: group))
    try await waitUntil { group.messages.last?.metadata["steer"] == "queued" }
    await backend.emit(step(.started), step(.completed), .token("After."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    let rows = group.messages.filter { $0.role != .system }
    #expect(rows.map(\.content) == ["@DMT hello", "Before. ", "shorter", "After."])
    #expect(rows[3].authorID == dmt.id && rows[3].metadata[TurnKey.part] == "2" && rows[3].metadata[TurnKey.forUser] == rows[0].id.uuidString)
    #expect(await backend.calls.all.filter { $0.hasPrefix("stop") }.isEmpty)
}

@MainActor @Test func textTypedWhileTheAnswerOnlyWritesSteersItWithoutStoppingIt() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.steerHint == nil)
    #expect(store.send(text: " use metric "))
    #expect(store.steerHint == SteerCopy.hint, "the first steer shows the one-time caption")
    try await backend.calls.wait { $0.contains("steer:use metric") }
    try await waitUntil { bot.messages.last?.metadata["steer"] == "queued" }
    #expect(await backend.calls.all == ["send:go", "steer:use metric"], "no Stop is ever requested")
    let partial = bot.messages[1]
    #expect(store.anyTurnRunning && partial.turnState == .incomplete && partial.isStreaming, "the answer keeps streaming")
    await backend.emit(.token("still writing."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(partial.content == "Before. still writing." && partial.turnState == .finished, "the answer finished whole")
    #expect(await backend.calls.all.filter { $0.hasPrefix("stop") }.isEmpty)
}

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
    try await waitUntil { !store.anyTurnRunning }

    let rows = bot.messages
    #expect(rows.map(\.role) == [.user, .assistant, .user, .assistant], "[user, assistant(part before), steer, assistant(rest)]")
    #expect(rows[1].content == "Before. still before. " && rows[1].metadata[TurnKey.part] == "1" && rows[1].turnState == .finished)
    #expect(rows[2].isSteer && rows[2].metadata["steer"] == "delivered" && SteerCopy.caption(rows[2]) == "Delivered")
    #expect(rows[3].content == "After." && rows[3].metadata[TurnKey.part] == "2" && rows[3].turnState == .finished && !rows[3].isStreaming)
    #expect(rows[1].activity?.total == 1 && rows[3].activity?.total == 1, "steps after delivery land on the new row")
    #expect(SidebarFragment.text(messages: rows, draft: nil, isWorking: false, archiveNewest: nil) == "After.")

    let reloaded = try #require(AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults()).bots.first)
    #expect(reloaded.messages.map(\.content) == ["go", "Before. still before. ", "use metric", "After."])
    #expect(reloaded.messages.map { $0.metadata[TurnKey.part] } == [nil, "1", nil, "2"])
}
