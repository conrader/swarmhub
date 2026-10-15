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
        let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
        let bot = store.bots[0]; store.selectedBot = bot
        return (store, bot)
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
        #expect(bot.messages.filter { $0.metadata[SteerKey.steer] == "sentNext" }.count == 2)
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
        #expect(bot.messages.contains { $0.role == .system && $0.content.contains("not confirmed yet") })
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

    @Test func queuedReviewNotesSurviveAQuit() async throws {
        let url = temporaryStore()
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend, url: url)
        try await startSteerableTurn(store, backend, running: false)
        let card = ChatMessage(role: .assistant, content: "", presentation: .review, metadata: [ReviewKey.state: "changes", ReviewKey.notes: "Cite the source."])
        bot.messages.append(card)
        #expect(store.sendReviewNotes(card) && card.metadata[ReviewKey.sent] == "1")
        let resumed = ScriptedTurnBackend()
        let (reopened, copy) = reopen(url, resumed)
        #expect(reopened.turns.nextMessages.first?.kind == .reviewNotes)
        copy.messages.first { $0.role == .assistant && $0.presentation == .text }?.turnState = .finished
        reopened.resumeRestoredNextMessages()
        try await resumed.calls.wait { $0.contains { $0.hasPrefix("send:Review notes from") } }
        await resumed.emit(.completed); await resumed.end(); try await waitUntil { !reopened.anyTurnRunning }
        store.turns.nextMessages = []; await backend.end(); try await waitUntil { !store.anyTurnRunning }
    }
}
