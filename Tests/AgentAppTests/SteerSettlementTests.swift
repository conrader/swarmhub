import Foundation
import Testing
@testable import AgentApp

@MainActor struct SteerSettlementTests {
    @Test func aReplyWithNoToolEventsDeliversBothQueuedSteers() async throws {
        let url = temporaryStore()
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend, url: url)
        #expect(store.send(text: "go"))
        try await backend.calls.wait { $0.contains("send:go") }
        try await waitUntil { store.canSteer(in: bot) }

        let first = try await queueSteer("use metric", in: store, bot: bot)
        let second = try await queueSteer("round the numbers", in: store, bot: bot)
        store.reconcileOrphanedSteers()
        #expect([first, second].map { $0.metadata[SteerKey.steer] } == ["delivered", "delivered"])
        await backend.emit(.replace("42 km."), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(bot) }

        #expect(bot.messages.map(\.content) == ["go", "use metric", "round the numbers", "42 km."])
        #expect(bot.messages.last?.turnState == .finished && bot.messages.last?.activity == nil)
        #expect([first, second].map { $0.metadata[SteerKey.steer] } == ["delivered", "delivered"])
        #expect([first, second].map { SteerCopy.caption($0) } == ["Delivered", "Delivered"])
        let saved = try StoreFile.decode(Data(contentsOf: url))
        #expect(saved.bots.first?.messages.filter(\.isSteer).map { $0.metadata[SteerKey.steer] } == ["delivered", "delivered"])
    }

    @Test(arguments: [true, false]) func anInterruptedTurnFailsQueuedSteersAndLetsPendingRequestsSettle(stopped: Bool) async throws {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend)
        try await startSteerableTurn(store, backend, running: false)
        let queued = try await queueSteer("use metric", in: store, bot: bot)
        await backend.holdSteers()
        #expect(store.send(text: "round the numbers"))
        try await backend.calls.wait { $0.contains("steer-held:round the numbers") }
        let sent = try #require(bot.messages.last)
        #expect(sent.metadata[SteerKey.steer] == "sent")

        if stopped {
            store.stop(bot)
            try await backend.calls.wait { $0.contains("stop:run-1") }
        } else {
            await backend.emit(.failed("could not finish"))
        }
        await backend.end()
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.messages[1].turnState == (stopped ? .stopped : .incomplete))
        #expect(SteerCopy.caption(queued) == "Delivered" && !store.canSendAsNextMessage(queued))
        #expect(sent.metadata[SteerKey.steer] == "sent")
        #expect(!store.canSendAsNextMessage(sent))

        await backend.releaseSteers()
        try await waitUntil { !store.turns.inFlightSteers.contains(sent.id) }
        #expect(sent.metadata[SteerKey.steer] == "delivered")
    }

    @Test(arguments: [true, false]) func aLateRefusalNeverStartsAnotherTurn(stopped: Bool) async throws {
        let backend = ScriptedTurnBackend(steerFails: true, steerError: .http(404, "run_not_found"))
        let (store, bot) = steerStore(backend)
        try await startSteerableTurn(store, backend, running: false)
        await backend.holdSteers()
        #expect(store.send(text: "use metric"))
        try await backend.calls.wait { $0.contains("steer-held:use metric") }
        let bubble = try #require(bot.messages.last)

        if stopped {
            store.stop(bot)
            try await backend.calls.wait { $0.contains("stop:run-1") }
        } else {
            await backend.emit(.failed("could not finish"))
        }
        await backend.end()
        try await waitUntil { store.isIdle(bot) }
        store.reconcileOrphanedSteers()
        #expect(bubble.metadata[SteerKey.steer] == "sent")

        await backend.releaseSteers()
        try await waitUntil { !store.turns.inFlightSteers.contains(bubble.id) }
        #expect(store.canSendAsNextMessage(bubble))
        #expect(await backend.streamCount == 1)
    }

    @Test func aLateAcknowledgementSettlesAfterSuccessfulCompletion() async throws {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend)
        try await startSteerableTurn(store, backend, running: false)
        await backend.holdSteers()
        #expect(store.send(text: "use metric"))
        try await backend.calls.wait { $0.contains("steer-held:use metric") }
        let bubble = try #require(bot.messages.last)
        #expect(bubble.metadata[SteerKey.steer] == "sent")

        await backend.emit(.replace("42 km."), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(bot) }
        await backend.releaseSteers()
        try await waitUntil { bubble.metadata[SteerKey.steer] != "sent" }
        #expect(bubble.metadata[SteerKey.steer] == "delivered")
        #expect(bot.messages.map(\.content) == ["go", "42 km.", "use metric"], "a late receipt cannot date text already visible")
    }

    @Test func aGroupMemberDeliversQueuedSteersWhenItsReplyFinishes() async throws {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend)
        let other = Bot(name: "Other", backend: .herdr)
        store.bots.append(other)
        let group = try #require(store.createGroup(name: "Pair", memberIDs: [bot.id, other.id]))
        #expect(store.send(text: "@Steer hello", to: group))
        try await waitUntil { store.canSteer(in: group) }
        #expect(store.send(text: "use metric", to: group))
        let bubble = try #require(group.messages.last)
        try await waitUntil { bubble.metadata[SteerKey.steer] == "delivered" }

        await backend.emit(.replace("42 km."), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(group) }
        #expect(bubble.metadata[SteerKey.steer] == "delivered")
    }

    @Test func reopeningSettlesOrphanedSteersAndSavesTheirStates() throws {
        let url = temporaryStore()
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend, url: url)
        let other = Bot(name: "Other", backend: .herdr)
        store.bots.append(other)
        let group = try #require(store.createGroup(name: "Pair", memberIDs: [bot.id, other.id]))
        bot.messages = [
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .assistant, content: "A complete reply", turnState: .finished),
            steer("accepted", state: "queued"),
            steer("unacknowledged", state: "sent"),
            ChatMessage(role: .user, content: "unanswered"),
            steer("missing reply", state: "queued"),
            steer("already delivered", state: "delivered"),
            steer("already failed", state: "failed")
        ]
        group.messages = [
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .assistant, content: "First part", metadata: [TurnKey.part: "1"], authorID: bot.id, turnState: .finished),
            steer("interrupted", state: "queued"),
            ChatMessage(role: .assistant, content: "Partial continuation", metadata: [TurnKey.part: "2"], authorID: bot.id, turnState: .incomplete),
            ChatMessage(role: .assistant, content: "Other member's reply", authorID: other.id, turnState: .finished),
            steer("accepted by other member", state: "queued")
        ]
        store.save()
        store.rememberRestoreUndo(try Data(contentsOf: url))

        let reopened = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: store.defaults)
        let data = try Data(contentsOf: url)
        let saved = try StoreFile.decode(data)
        let botStates = ["uncertain", "uncertain", "uncertain", "delivered", "failed"]
        let groupStates = ["uncertain", "uncertain"]
        #expect(reopened.bots.first?.messages.filter(\.isSteer).compactMap { $0.metadata[SteerKey.steer] } == botStates)
        #expect(reopened.groups.first?.messages.filter(\.isSteer).compactMap { $0.metadata[SteerKey.steer] } == groupStates)
        #expect(saved.bots.first?.messages.filter(\.isSteer).compactMap { $0.metadata[SteerKey.steer] } == botStates)
        #expect(saved.groups.first?.messages.filter(\.isSteer).compactMap { $0.metadata[SteerKey.steer] } == groupStates)
        #expect(reopened.restoreUndoRevision == data)
    }

    private func queueSteer(_ text: String, in store: AppStore, bot: Bot) async throws -> ChatMessage {
        #expect(store.send(text: text))
        let bubble = try #require(bot.messages.last)
        #expect(bubble.content == text)
        try await waitUntil { bubble.metadata[SteerKey.steer] == "delivered" }
        return bubble
    }

    private func steer(_ text: String, state: String) -> ChatMessage {
        ChatMessage(role: .user, content: text, metadata: [SteerKey.steer: state])
    }
}
