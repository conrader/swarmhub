import Foundation
import Testing
@testable import AgentApp

// uxfix1-e2e: messages typed while a turn runs wait, then go one turn each, in order, each exactly once. A queued
// message's turn sends the chat only up to it (Hermes sends the last user row), and its reply sits right under it.

@MainActor @Test func twoMessagesQueuedDuringATurnGoOnceEachInOrder() async throws {
    let backend = ScriptedTurnBackend(steerless: true)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "A") && store.send(text: "B"), "both wait for the running turn")
    #expect(bot.messages.filter { $0.metadata[TurnWaitCopy.key] == "waiting" }.map(\.content) == ["A", "B"])
    await backend.emit(.token("Done."), .completed); await backend.end()
    try await backend.calls.wait { $0.contains("send:A") }
    #expect(await backend.calls.all == ["send:go", "send:A"], "A goes alone: its turn does not carry B")
    let a = try #require(bot.messages.firstIndex { $0.content == "A" })
    #expect(bot.messages[a + 1].role == .assistant && bot.messages[a + 1].isStreaming, "A's reply sits right under A, above waiting B")
    #expect(store.hasWaitingTurn(in: bot), "B still waits")
    await backend.emit(.token("For A."), .completed); await backend.end()
    try await backend.calls.wait { $0.contains("send:B") }
    await backend.emit(.token("For B."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning && !store.hasWaitingTurn(in: bot) }
    #expect(await backend.calls.all == ["send:go", "send:A", "send:B"], "each message reached the box exactly once")
    #expect(bot.messages.filter { $0.role != .system }.map(\.content) == ["go", "Before. Done.", "A", "For A.", "B", "For B."])
    let probe = ChatMessage(role: .assistant, content: "")
    #expect(store.chatHistory(bot, excluding: probe).map(\.content) == ["go", "Before. Done.", "A", "For A.", "B", "For B."])
}

@MainActor @Test func aQueuedMessagesTurnSendsHistoryOnlyUpToIt() async throws {
    let backend = ScriptedTurnBackend(steerless: true)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "A") && store.send(text: "B"))
    let a = try #require(bot.messages.first { $0.content == "A" })
    let reply = ChatMessage(role: .assistant, content: "")
    let history = store.chatHistory(bot, upTo: a, excluding: reply).map(\.content)
    #expect(history.last == "A" && !history.contains("B"))
    await backend.emit(.completed); await backend.end()
    try await backend.calls.wait { $0.contains("send:A") }
    await backend.emit(.completed); await backend.end()
    try await backend.calls.wait { $0.contains("send:B") }
    await backend.emit(.completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning && !store.hasWaitingTurn(in: bot) }
}
