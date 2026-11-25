import Foundation
import Testing
@testable import AgentApp

// P28: steer that actually lands. uxfix1: a message typed during a turn never stops it: it steers the turn, or waits and
// goes when the turn ends (no steer on the runtime, attachments). Bubble copy, D5 order on screen (store, reload, history,
// sidebar) and the box handing a steer back. Synthetic backends only.

@Test func bubbleCopyPerPath() {
    func caption(_ metadata: [String: String]) -> String? { SteerCopy.caption(ChatMessage(role: .user, content: "x", metadata: metadata)) }
    #expect(caption([:]) == nil)
    #expect(caption(["steer": "sent"]) == "Accepted · sending to current turn…")
    #expect(caption(["steer": "queued"]) == "Accepted · delivery unconfirmed")
    #expect(caption(["steer": "delivered"]) == "Delivered")
    #expect(caption(["steer": "failed"]) == "Not delivered")
    #expect(SteerCopy.endedFirst == "The answer ended first.", "the line under a failed steer gives only the reason")
    // Rows saved before uxfix1 still read as they did.
    #expect(caption(["correction": "stopping"]) == "Stopping the answer…")
    #expect(caption(["correction": "stopped"]) == "Stopped the answer and sent your correction")
    #expect(caption(["correction": "followup"]) == "Sent after the answer finished")
    #expect(SteerCopy.placeholder == "Add to this answer…")
    #expect(SteerCopy.hint == "Follow-ups go to the current turn. Check the receipt below your message.")
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
    await backend.emit(.token("Done."), .completed); await backend.end()
    try await backend.calls.wait { $0.contains("send:and then this") }
    await backend.emit(.token("Second reply."), .completed); await backend.end()
    try await waitUntil { store.isIdle(bot) }
    #expect(await backend.calls.all == ["send:go", "send:and then this"])
    #expect(bot.messages.filter { $0.role == .user }.map(\.id) == [bot.messages[0].id, waiting.id])
}

@MainActor @Test func attachmentAndReplyReachTheActiveTurn() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: true)
    store.replyTo = bot.messages.first
    let file = ChatAttachment(id: UUID(), kind: .text, name: "notes.txt", mimeType: "text/plain", byteCount: 5, text: "notes")
    #expect(store.send(text: "see this", attachments: [file]))
    let receipt = try #require(bot.messages.last)
    try await waitUntil { receipt.metadata[SteerKey.steer] == "delivered" }
    #expect(receipt.replyToID == bot.messages.first?.id && receipt.attachments == [file])
    #expect(await backend.calls.all == ["send:go", "file:notes.txt:notes", "steer:In reply to “go”\nsee this"])
    #expect(!store.isIdle(bot))
    await backend.emit(.completed); await backend.end()
    try await waitUntil { store.isIdle(bot) }
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
    let original = bot.messages[1]
    await backend.emit(.token("More."))
    try await waitUntil { original.content == "Before. More." }
    #expect(bot.messages[1] === original && bot.messages[2] === bubble)
    store.stop(); try await waitUntil { !store.anyTurnRunning }
}

// MARK: D5 order on screen

// MARK: A steer the box hands back

// MARK: Groups

@MainActor @Test func anUnsupportedGroupFollowUpWaitsForItsOriginalRecipient() async throws {
    let backend = ScriptedTurnBackend(steerless: true)
    let (store, first) = steerStore(backend), second = Bot(name: "Other")
    store.bots.append(second)
    let group = try #require(store.createGroup(name: "Team", memberIDs: [first.id, second.id]))
    #expect(store.send(text: "@Steer first question", to: group))
    try await backend.calls.wait { $0.count == 1 }
    #expect(store.send(text: "@Steer second question", to: group))
    let row = try #require(group.messages.first { $0.content == "@Steer second question" })
    #expect(row.metadata[TurnWaitCopy.recipients] == first.id.uuidString && row.metadata[TurnWaitCopy.key] == "waiting")
    #expect(await backend.streamCount == 1)
    await backend.emit(.token("First reply"), .completed); await backend.end()
    try await backend.calls.wait { $0.count == 2 }
    await backend.emit(.token("Second reply"), .completed); await backend.end()
    try await waitUntil { store.isIdle(group) }
    #expect(group.messages.filter { $0.role == .user && $0.content == row.content }.map(\.id) == [row.id])
    #expect(group.messages.last { $0.role == .assistant }?.authorID == first.id)
}

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
    try await waitUntil { group.messages.last?.metadata["steer"] == "delivered" }
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
    try await waitUntil { bot.messages.last?.metadata["steer"] == "delivered" }
    #expect(await backend.calls.all == ["send:go", "steer:use metric"], "no Stop is ever requested")
    let partial = bot.messages[1]
    #expect(store.anyTurnRunning && partial.turnState == .incomplete && partial.isStreaming, "the answer keeps streaming")
    await backend.emit(.token("still writing."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.messages.map(\.content) == ["go", "Before. ", " use metric ", "still writing."])
    #expect(partial.turnState == .finished && bot.messages.last?.turnState == .finished)
    #expect(await backend.calls.all.filter { $0.hasPrefix("stop") }.isEmpty)
}

@MainActor @Test func aSteerDeliveredMidReplyContinuesInANewRowBelowIt() async throws {
    let url = temporaryStore()
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend, url: url)
    try await startSteerableTurn(store, backend, running: true)
    #expect(store.send(text: "use metric"))
    try await backend.calls.wait { $0.contains("steer:use metric") }
    try await waitUntil { bot.messages.last?.metadata["steer"] == "delivered" }
    await backend.emit(.token("New text. "), step(.completed), .token("After."), step(.started, id: "c2"), step(.completed, id: "c2"), .completed)
    await backend.end()
    try await waitUntil { !store.anyTurnRunning }

    let rows = bot.messages
    #expect(rows.map(\.role) == [.user, .assistant, .user, .assistant], "[user, assistant(part before), steer, assistant(rest)]")
    #expect(rows[1].content == "Before. " && rows[1].metadata[TurnKey.part] == "1" && rows[1].turnState == .finished)
    #expect(rows[2].isSteer && rows[2].metadata["steer"] == "delivered" && SteerCopy.caption(rows[2]) == "Delivered")
    #expect(rows[3].content == "New text. After." && rows[3].metadata[TurnKey.part] == "2" && rows[3].turnState == .finished && !rows[3].isStreaming)
    #expect(rows[1].activity?.total == 1 && rows[3].activity?.total == 1, "steps after delivery land on the new row")
    #expect(SidebarFragment.text(messages: rows, draft: nil, isWorking: false, archiveNewest: nil) == "New text. After.")

    let reloaded = try #require(AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults()).bots.first)
    #expect(reloaded.messages.map(\.content) == ["go", "Before. ", "use metric", "New text. After."])
    #expect(reloaded.messages.map { $0.metadata[TurnKey.part] } == [nil, "1", nil, "2"])
}

@MainActor @Test func aSteerDeliveredMidReplyStripsCumulativeReplacesFromEarlierParts() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    #expect(store.send(text: "go"))
    try await backend.calls.wait { $0.contains("send:go") }
    await backend.emit(.replace("First paragraph."), step(.started))
    try await waitUntil { store.soleTurn?.steerAvailable == true && store.soleTurn?.assistant?.content == "First paragraph." }

    #expect(store.send(text: "use metric"))
    try await backend.calls.wait { $0.contains("steer:use metric") }
    try await waitUntil { bot.messages.last?.metadata["steer"] == "delivered" }

    await backend.emit(step(.completed), .replace("First paragraph.\n\nSecond paragraph in metric."), step(.started, id: "c2"))
    try await waitUntil { bot.messages.count == 4 && bot.messages[3].content == "Second paragraph in metric." }

    #expect(store.send(text: "just the number"))
    try await backend.calls.wait { $0.contains("steer:just the number") }
    try await waitUntil { bot.messages.last?.metadata["steer"] == "delivered" }

    // A final replace that does not repeat earlier prefixes still lands whole in the new part.
    await backend.emit(step(.completed, id: "c2"), .replace("42"), .completed)
    await backend.end()
    try await waitUntil { !store.anyTurnRunning }

    #expect(bot.messages.map(\.content) == ["go", "First paragraph.", "use metric", "Second paragraph in metric.", "just the number", "42"])
    #expect(bot.messages.map { $0.metadata[TurnKey.part] } == [nil, "1", nil, "2", nil, "3"])
}

@MainActor @Test func multiSelectDuringBlockedCodexTurnStaysGuidance() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    store.defaults.set(false, forKey: HerdrBackend.botSteerKey(bot.id))
    #expect(store.herdrSteers(bot))
    #expect(store.defaults.object(forKey: HerdrBackend.botSteerKey(bot.id)) != nil)
    let question = "Which fixture folders?"
    let source = ChatMessage(role: .assistant, content: "```choices-multiple\n\(question)\n- A\n- B\n```")
    bot.messages = [source]
    try await startSteerableTurn(store, backend, running: true)
    store.markAutoSwitch(bot)
    store.herdrTurnStatus(.blocked(program: "Codex"), for: bot)
    let block = try #require(ChatCardParser.parse(source.content).first)
    #expect(store.performCardAction(target: .bot(botID: bot.id), sourceID: source.id, index: 0,
                                   expected: block, choice: .multiple(["B", "A"], other: "")))
    let receipt = try #require(bot.messages.last)
    try await waitUntil { receipt.metadata[SteerKey.steer] == "delivered" }
    #expect(receipt.replyToID == source.id && receipt.content == "A\nB")
    #expect(await backend.calls.all.last == "steer:In reply to “Steer: \(question)”\nA\nB")
    #expect(store.herdrWaits(bot).waits && store.autoSwitchPending(bot))
    await backend.emit(.completed); await backend.end()
    try await waitUntil { store.isIdle(bot) }
    #expect(await backend.streamCount == 1)
}

@MainActor @Test func groupMemberCanStartWhileAnotherMemberReceivesGuidance() async throws {
    let first = ScriptedTurnBackend(), second = ScriptedTurnBackend()
    let doc = Bot(name: "Doc"), boppy = Bot(name: "Boppy")
    let id = doc.id
    let store = AppStore(storeURL: temporaryStore(), autoStart: false,
                         backendFactory: { $0.id == id ? first : second }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = [doc, boppy]
    let group = try #require(store.createGroup(name: "Fixture", memberIDs: [doc.id, boppy.id]))
    #expect(store.send(text: "@Doc read this", to: group))
    try await waitUntil { store.canSteer(in: group) }
    let card = ChatMessage(role: .assistant, content: "```choices\nWhich fixture?\n- A\n- B\n```", authorID: boppy.id)
    group.messages.insert(card, at: 0)
    let block = try #require(ChatCardParser.parse(card.content).first)
    #expect(store.performCardAction(target: .group(groupID: group.id, botID: boppy.id),
                                   sourceID: card.id, index: 0, expected: block, choice: .option("B")))
    try await second.calls.wait { $0.contains { $0.contains("Which fixture?") && $0.contains("B") } }
    #expect(store.send(text: "@Doc include the filename", to: group))
    try await first.calls.wait { $0.contains("steer:@Doc include the filename") }
    #expect(await second.calls.all.allSatisfy { !$0.hasPrefix("steer:") })
    await first.emit(.completed); await first.end()
    await second.emit(.completed); await second.end()
    try await waitUntil { store.isIdle(group) }
    #expect(store.turns.nextMessages.isEmpty)
}
