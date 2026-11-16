import Foundation
import Testing
@testable import AgentApp

// Retry sends a reply that was not sent once more, into the same row. Scripted backends; no network.

/// A bot chat holding one unsent turn: a user row and its empty `notSent` reply row.
@MainActor private func unsentChat(_ backend: ScriptedTurnBackend, text: String = "please answer", ambiguous: Bool = false) -> (AppStore, Bot, ChatMessage) {
    let (store, bot) = steerStore(backend)
    var metadata = ["why": "offline"]
    if ambiguous { metadata[TurnKey.ambiguous] = "1" }
    let row = ChatMessage(role: .assistant, content: "", metadata: metadata, turnState: .notSent)
    bot.messages = [ChatMessage(role: .user, content: text), row]
    return (store, bot, row)
}

@MainActor @Test func retrySendsTheMessageAgainIntoTheSameRow() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot, row) = unsentChat(backend)
    #expect(store.canRetry(row))
    store.retry(row)
    #expect(store.anyTurnRunning, "the chat's slot is claimed at once")
    try await backend.calls.wait { $0.contains("send:please answer") }
    await backend.emit(.token("Here it is."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.messages.count == 2, "no new row: the reply went into the row that was not sent")
    #expect(row.content == "Here it is." && row.turnState == .finished && row.metadata[TurnKey.why] == nil)
    #expect(!store.canRetry(row), "a finished reply offers no Retry")
    #expect(await backend.calls.all.filter { $0.hasPrefix("send:") }.count == 1, "sent once")
}

@MainActor @Test func aReplyTheAgentMayAlreadyHaveNeedsASecondTap() async throws {
    let backend = ScriptedTurnBackend()
    let (store, _, row) = unsentChat(backend, ambiguous: true)
    store.retry(row)
    #expect(row.metadata[TurnKey.retry] == "confirm" && !store.anyTurnRunning, "the first tap only asks")
    #expect(await backend.calls.all.isEmpty)
    store.retry(row)
    try await backend.calls.wait { $0.contains("send:please answer") }
    await backend.emit(.token("ok"), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(row.turnState == .finished && row.metadata[TurnKey.retry] == nil && row.metadata[TurnKey.ambiguous] == nil)
}

@MainActor @Test func retryIsOfferedOnlyOnARowThatWasNotSent() {
    let backend = ScriptedTurnBackend()
    let (store, bot, row) = unsentChat(backend)
    let finished = ChatMessage(role: .assistant, content: "done", turnState: .finished)
    let incomplete = ChatMessage(role: .assistant, content: "half", turnState: .incomplete)
    bot.messages += [finished, incomplete]
    #expect(store.canRetry(row) && !store.canRetry(finished) && !store.canRetry(incomplete) && !store.canRetry(bot.messages[0]))
}

@MainActor @Test func aRetryThatFailsAgainLeavesTheRowNotSentWithItsWarning() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot, row) = unsentChat(backend)
    store.retry(row)
    try await backend.calls.wait { $0.contains("send:please answer") }
    await backend.fail(BackendError.http(401, "refused"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(row.turnState == .notSent && row.metadata[TurnKey.why] == "refused" && store.canRetry(row))
    #expect(bot.messages.contains { $0.role == .system && $0.metadata[TurnKey.tone] == "warning" }, "the failure is a line in the chat")
}
