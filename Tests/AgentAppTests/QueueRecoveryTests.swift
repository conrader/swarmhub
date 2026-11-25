import Foundation
import Testing
@testable import AgentApp

// P38 E: the next-message queue survives a quit (run ledger, kind `nextMessage`): it resumes in order once the earlier
// reply is confirmed, goes back to the user when it is not or when the text changed, and is never sent twice.
// Scripted backends; no network.

@MainActor struct QueueRecoveryTests {
    /// A running turn with two failed steers queued behind it, saved; then the app "quits" (the store is dropped).
    func queuedBehindARunningTurn(url: URL) async throws -> (AppStore, ScriptedTurnBackend, [ChatMessage]) {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend, url: url)
        try await startSteerableTurn(store, backend, running: false)
        let bubbles = ["first correction", "second correction"].map { ChatMessage(role: .user, content: $0, metadata: [SteerKey.steer: "failed"]) }
        bot.messages.append(contentsOf: bubbles)
        for bubble in bubbles { #expect(store.sendAsNextMessage(bubble)) }
        #expect(store.turns.nextMessages.count == 2 && bubbles.allSatisfy { $0.metadata[SteerKey.steer] == "next" })
        store.save()
        return (store, backend, bubbles)
    }

    func reopen(_ url: URL, _ backend: ScriptedTurnBackend) -> (AppStore, Bot) {
        let store = AppStore(storeURL: url, autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = store.bots[0]; store.selectedBot = bot
        return (store, bot)
    }

    @Test func interruptedDispatchRetainsTextWithoutReplay() async throws {
        let url = temporaryStore()
        let (original, first, _) = try await queuedBehindARunningTurn(url: url)
        let next = try #require(original.turns.nextMessages.first)
        #expect(original.recordNextMessage(next, .submitting))
        let backend = ScriptedTurnBackend()
        let (store, bot) = reopen(url, backend)
        #expect(!store.turns.nextMessages.contains { $0.id == next.id })
        #expect(bot.messages.contains { $0.content.contains("delivery is uncertain") && $0.content.contains(next.bubble.content) })
        let records = try store.journal().records(NextMessageRecord.self, kind: AppStore.nextMessageKind)
        #expect(records.contains { $0.id == next.id && $0.state == .uncertain && $0.text == next.bubble.content })
        #expect(backend.calls.all.isEmpty)
        original.turns.nextMessages = []
        await first.end()
        try await waitUntil { !original.anyTurnRunning }
    }

    @Test func theQueueResumesInOrderAfterTheEarlierReplyIsConfirmed() async throws {
        let url = temporaryStore()
        let (original, first, _) = try await queuedBehindARunningTurn(url: url)
        let backend = ScriptedTurnBackend()
        let (store, bot) = reopen(url, backend)
        #expect(store.turns.nextMessages.map(\.bubble.content) == ["first correction", "second correction"])
        #expect(store.turns.nextMessages.allSatisfy { $0.restored })
        store.sendQueuedNextMessage()
        #expect(backend.calls.all.isEmpty, "held until the launch reconcile ran")
        // The launch reconcile found the reply the quit cut off finished.
        bot.messages.first { $0.role == .assistant }?.turnState = .finished
        store.resumeRestoredNextMessages()
        try await backend.calls.wait { $0.contains("send:first correction") }
        #expect(!backend.calls.all.contains("send:second correction"))
        await backend.emit(.token("One."), .completed); await backend.end()
        try await backend.calls.wait { $0.contains("send:second correction") }
        await backend.emit(.token("Two."), .completed); await backend.end()
        try await waitUntil { !store.anyTurnRunning && store.turns.nextMessages.isEmpty }
        #expect(bot.messages.filter { $0.metadata[SteerKey.explicitNext] == "1" && !$0.isSteer }.count == 2)
        // Sent entries are never sent again.
        let again = ScriptedTurnBackend()
        let (third, _) = reopen(url, again)
        #expect(third.turns.nextMessages.isEmpty)
        original.turns.nextMessages = []; await first.end(); try await waitUntil { !original.anyTurnRunning }
    }

    @Test func anUnconfirmedEarlierReplyGivesTheQueueBackWithALine() async throws {
        let url = temporaryStore()
        let (original, first, bubbles) = try await queuedBehindARunningTurn(url: url)
        let backend = ScriptedTurnBackend()
        let (store, bot) = reopen(url, backend)
        #expect(bot.messages.first { $0.role == .assistant }?.turnState == .incomplete)
        store.resumeRestoredNextMessages()
        #expect(store.turns.nextMessages.isEmpty && backend.calls.all.isEmpty)
        let restored = bot.messages.filter { bubbles.map(\.id).contains($0.id) }
        #expect(restored.count == 2 && restored.allSatisfy { $0.metadata[SteerKey.steer] == "failed" && store.canSendAsNextMessage($0) })
        #expect(bot.messages.contains { $0.role == .system && $0.content.contains("did not finish") })
        let (third, _) = reopen(url, ScriptedTurnBackend())
        #expect(third.turns.nextMessages.isEmpty, "given back for good")
        original.turns.nextMessages = []; await first.end(); try await waitUntil { !original.anyTurnRunning }
    }

    @Test func aChangedTextIsGivenBackInsteadOfSent() async throws {
        let url = temporaryStore()
        let (original, first, bubbles) = try await queuedBehindARunningTurn(url: url)
        bubbles[0].content = "edited after it was queued"; original.save()
        let (store, bot) = reopen(url, ScriptedTurnBackend())
        #expect(store.turns.nextMessages.map(\.bubble.content) == ["second correction"])
        #expect(bot.messages.first { $0.id == bubbles[0].id }?.metadata[SteerKey.steer] == "failed")
        original.turns.nextMessages = []; await first.end(); try await waitUntil { !original.anyTurnRunning }
    }

    @Test func unsupportedTurnQueueResumesOnceWithoutReplayingPreUpgradeGuidance() async throws {
        let url = temporaryStore(), first = ScriptedTurnBackend(steerless: true)
        let (original, bot) = steerStore(first, url: url)
        try await startSteerableTurn(original, first, running: false)
        let legacy = ChatMessage(role: .user, content: "Old guidance")
        bot.messages.append(legacy)
        #expect(original.waitForTurn(legacy, in: bot, reason: SteerCopy.afterTurn))
        #expect(original.send(text: "Next question"))
        original.save()

        let backend = ScriptedTurnBackend(), (store, restored) = reopen(url, backend)
        #expect(store.turns.nextMessages.map(\.bubble.content) == ["Next question"])
        let old = try #require(restored.messages.first { $0.id == legacy.id })
        #expect(store.canSendAsNextMessage(old))
        restored.messages.first { $0.role == .assistant }?.turnState = .finished
        store.resumeRestoredNextMessages()
        try await backend.calls.wait { $0.contains("send:Next question") }
        await backend.end()
        try await waitUntil { store.isIdle(restored) }
        #expect(backend.calls.all == ["send:Next question"])
        #expect(restored.messages.filter { $0.content == "Next question" }.count == 1)
        original.turns.nextMessages = []
        await first.end()
        try await waitUntil { original.isIdle(bot) }
    }

    @Test func aRefusedLedgerWriteQueuesNothing() async throws {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend)
        try await startSteerableTurn(store, backend, running: false)
        let bubble = ChatMessage(role: .user, content: "later", metadata: [SteerKey.steer: "failed"]); bot.messages.append(bubble)
        let ledger = try store.journal(); store.runtime = RejectingRuntime()
        #expect(!store.sendAsNextMessage(bubble))
        #expect(store.turns.nextMessages.isEmpty && bubble.metadata[SteerKey.steer] == "failed")
        #expect(store.errorMessage?.contains("Could not save the message queue") == true)
        store.runtime = ledger
        await backend.end(); try await waitUntil { !store.anyTurnRunning }
        #expect(!backend.calls.all.contains("send:later"))
    }

}
