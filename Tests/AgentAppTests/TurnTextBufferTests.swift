import Combine
import Foundation
import Testing
@testable import AgentApp

@MainActor struct TurnTextBufferTests {
    @Test func snapshotsSupersedeTokensAndQuietTailsReachObservers() async throws {
        let row = ChatMessage(role: .assistant, content: "")
        var orderChanges: [Bool] = []
        let buffer = TurnTextBuffer { orderChanges.append($0) }
        let date = Date()
        for _ in 0..<100 { buffer.receive("old", replacing: false, row: row, at: date) }
        buffer.receive("Correct", replacing: true, row: row, at: date)
        buffer.receive(" 🐈", replacing: false, row: row, at: date)
        #expect(row.content.isEmpty)
        try await waitUntil { row.content == "Correct 🐈" }
        #expect(orderChanges == [true] && row.lastTextAt == date)
        buffer.flush()
        #expect(orderChanges.count == 1)
    }

    @Test func backgroundTextPreservesToolOffsetsWithoutBroadcastingEveryToken() async throws {
        let (store, bot) = steerStore(ScriptedTurnBackend())
        let row = ChatMessage(role: .assistant, content: "", isStreaming: true)
        bot.messages = [row]
        store.selectedBot = Bot(name: "Reading here")
        var storeUpdates = 0
        let observation = store.objectWillChange.sink { storeUpdates += 1 }
        defer { observation.cancel() }
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        pair.continuation.yield(.token("x"))
        for _ in 0..<64 { pair.continuation.yield(.token("🐈")) }
        pair.continuation.yield(step(.started))
        pair.continuation.yield(.replace("Final"))
        pair.continuation.yield(.token(" tail"))
        pair.continuation.finish(throwing: URLError(.networkConnectionLost))
        do {
            _ = try await store.consumeTurn(pair.stream, assistant: row, bot: bot)
            Issue.record("Expected the stream error")
        } catch let error as URLError { #expect(error.code == .networkConnectionLost) }
        #expect(row.activity?.steps.first?.textOffset == 129)
        #expect(row.content == "Final tail")
        #expect(storeUpdates == 2, "First visible content and the tool status each update the sidebar")
        store.flushNow()
        let disk = try StoreFile.decode(Data(contentsOf: store.fileURL))
        #expect(disk.bots.first?.messages.first?.content == "Final tail")
    }

    @Test func stopCommitsThePendingTailBeforeFreezingTheRow() async throws {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend)
        try #require(store.send(text: "Start"))
        try await waitUntil { store.turns.textBuffers[bot.id] != nil }
        let row = try #require(store.turn(in: bot)?.assistant)
        let buffer = try #require(store.turns.textBuffers[bot.id])
        buffer.receive("Accepted before Stop", replacing: false, row: row, at: Date())
        store.stop(bot)
        #expect(row.content == "Accepted before Stop" && row.turnState == .stopped)
        try await waitUntil { store.isIdle(bot) }
        #expect(row.content == "Accepted before Stop")
    }

    @Test func quitFlushIncludesPendingTextFromEveryConversation() throws {
        let (store, first) = steerStore(ScriptedTurnBackend())
        let second = Bot(name: "Other")
        store.bots.append(second)
        for bot in [first, second] {
            let row = ChatMessage(role: .assistant, content: "", isStreaming: true, turnState: .incomplete)
            bot.messages = [row]
            let buffer = TurnTextBuffer { _ in }
            store.turns.textBuffers[bot.id] = buffer
            buffer.receive(bot.name, replacing: false, row: row, at: Date())
        }
        store.flushNow()
        let disk = try StoreFile.decode(Data(contentsOf: store.fileURL))
        #expect(disk.bots.map { $0.messages.first?.content } == [first.name, second.name])
    }
}
