import Foundation
import Testing
@testable import AgentApp

// P38 E: the next-message queue survives a quit (run ledger, kind `nextMessage`): it resumes in order once the earlier
// reply is confirmed, goes back to the user when it is not or when the text changed, and is never sent twice.
// Scripted backends; no network.

@MainActor struct QueueRecoveryTests {
    @Test func queuePresentationKeepsMessagesAndShowsOnlyTheFirstWaitReason() {
        let first = ChatMessage(role: .user, content: "First", metadata: [TurnWaitCopy.key: "waiting"])
        let second = ChatMessage(role: .user, content: "Second", metadata: [TurnWaitCopy.key: "waiting"])
        let busy = ChatMessage(role: .system, content: TurnWaitCopy.busy, metadata: [TurnWaitCopy.key: "line"])
        let behind = ChatMessage(role: .system, content: TurnWaitCopy.behind, metadata: [TurnWaitCopy.key: "line"])
        let warning = ChatMessage(role: .system, content: TurnWaitCopy.notSent)
        let sent = ChatMessage(role: .user, content: TurnWaitCopy.behind)
        let queue = ChatQueuePresentation([sent, first, busy, second, behind, warning])
        #expect(queue.waiting.map(\.id) == [first.id, second.id])
        #expect(queue.transcript.map(\.id) == [sent.id, first.id, second.id, warning.id])
        #expect(queue.reason == TurnWaitCopy.busy)
        first.metadata[TurnWaitCopy.key] = nil
        let remaining = ChatQueuePresentation([first, second, behind, warning])
        #expect(remaining.waiting.map(\.id) == [second.id])
        #expect(remaining.reason == nil)
        #expect(ChatQueuePresentation([sent, warning]).waiting.isEmpty)
    }

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
        let legacy = ChatMessage(role: .user, content: "Old guidance", metadata: [TurnWaitCopy.key: "waiting"])
        bot.messages.append(legacy)
        bot.messages.append(ChatMessage(role: .system, content: SteerCopy.afterTurn, metadata: [TurnWaitCopy.key: "line"]))
        let oldRecord = NextMessageRecord(id: UUID(), anchorID: legacy.id, kind: .turn, text: legacy.content, state: .waiting)
        try original.journal().put(oldRecord, kind: AppStore.nextMessageKind, id: oldRecord.id.uuidString)
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

    @Test func capacityQueueDispatchesItsIndependentHeadAndFollowerAfterRestart() async throws {
        let url = temporaryStore(), backend = ScriptedTurnBackend()
        let (original, bot) = steerStore(backend, url: url)
        let busy = Bot(name: "Busy")
        original.bots.append(busy)
        original.setTotalTurnLimit(1)
        let slot = original.beginTurn(in: busy, bot: busy, assistant: nil)
        bot.messages.append(ChatMessage(role: .assistant, content: "Historical partial answer", turnState: .incomplete))
        #expect(original.send(text: "First"))
        #expect(original.send(text: "Second"))
        #expect(backend.calls.all.isEmpty)
        original.endTurn(slot.token)

        let (store, chat) = reopen(url, backend)
        store.resumeRestoredNextMessages()
        try await backend.calls.wait { $0 == ["send:First"] }
        store.sendQueuedNextMessage()
        await backend.emit(.completed); await backend.end()
        try await backend.calls.wait { $0 == ["send:First", "send:Second"] }
        await backend.emit(.completed); await backend.end()
        try await waitUntil { store.isIdle(chat) }
        #expect(backend.calls.all == ["send:First", "send:Second"])
    }

    @Test func recoveringTheExactReplyDispatchesTwoWaitingTurnsInOrder() async throws {
        let url = temporaryStore(), initial = ScriptedTurnBackend(steerless: true)
        let (original, bot) = steerStore(initial, url: url)
        let receipt = HerdrDeliveryReceipt(server: HerdrServer.defaultID,
            turn: .init(core: "c", address: "p", createdMs: 7, after: 10, launched: false), text: "First")
        let http = MockHTTPProtocol.serve { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/history/c/p/7" else { return (404, [:]) }
            return (200, ["items": [["id": 11, "kind": "task", "text": "First"], ["id": 12, "kind": "reply", "text": "Done"]]])
        }
        let server = HerdrServer(id: receipt.server, name: "Fixture", kind: .address, address: "http://\(http.host)")
        original.saveHerdrServer(server, token: "test")
        // This historical reply stays incomplete throughout, including after First is confirmed.
        bot.messages.append(ChatMessage(role: .assistant, content: "Older partial answer", turnState: .incomplete))
        #expect(original.send(text: "First"))
        try await initial.calls.wait { $0 == ["send:First"] }
        await initial.emit(.accepted(receipt))
        #expect(original.send(text: "Second"))
        #expect(original.send(text: "Third"))
        await initial.end()
        try await waitUntil { original.isIdle(bot) }
        #expect(initial.calls.all == ["send:First"])
        let first = try #require(bot.messages.first { $0.role == .user && $0.content == "First" })
        let second = try #require(bot.messages.first { $0.role == .user && $0.content == "Second" })
        let records = try original.journal().records(NextMessageRecord.self, kind: AppStore.nextMessageKind)
        #expect(records.compactMap(\.predecessor) == [.message(first.id), .message(second.id)])

        let backend = ScriptedTurnBackend(), (store, chat) = reopen(url, backend)
        store.saveHerdrServer(server, token: "test")
        store.herdrClientSetup = { $0.session = http.session }
        store.resumeRestoredNextMessages()
        let reply = try #require(chat.messages.first { $0.deliveryReceipt == receipt })
        #expect(store.isIdle(chat) && backend.calls.all.isEmpty)
        #expect(await !store.checkRecoveredReply(receipt, bot: chat, row: reply))
        try await backend.calls.wait { $0 == ["send:Second"] }
        #expect(await !store.checkRecoveredReply(receipt, bot: chat, row: reply))
        store.resumeRestoredNextMessages()
        await backend.emit(.token("Two"), .completed); await backend.end()
        try await backend.calls.wait { $0 == ["send:Second", "send:Third"] }
        await backend.emit(.token("Three"), .completed); await backend.end()
        try await waitUntil { store.isIdle(chat) }
        let (again, saved) = reopen(url, backend)
        again.resumeRestoredNextMessages()
        #expect(again.isIdle(saved) && backend.calls.all == ["send:Second", "send:Third"])
    }

    @Test func cancelQueuedFollowerWhileSavedReceiptStillWaits() async throws {
        let url = temporaryStore(), backend = ScriptedTurnBackend(steerless: true)
        let (original, bot) = steerStore(backend, url: url)
        let reads = AwaitableLog<String>()
        let http = MockHTTPProtocol.serve { request in
            reads.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return (200, ["items": [["id": 11, "kind": "task", "text": "First"]]])
        }
        let server = HerdrServer(id: HerdrServer.defaultID, name: "Fixture", kind: .address, address: "http://\(http.host)")
        original.saveHerdrServer(server, token: "test")
        let receipt = HerdrDeliveryReceipt(server: server.id,
            turn: .init(core: "c", address: "p", createdMs: 7, after: 10, launched: false), text: "First")
        #expect(original.send(text: "First"))
        try await backend.calls.wait { $0 == ["send:First"] }
        await backend.emit(.accepted(receipt))
        #expect(original.send(text: "Second"))
        #expect(original.send(text: "Third"))
        await backend.end()
        try await waitUntil { original.isIdle(bot) }

        let (store, chat) = reopen(url, backend)
        store.saveHerdrServer(server, token: "test")
        store.herdrClientSetup = { $0.session = http.session }
        store.resumeRestoredNextMessages()
        let reply = try #require(chat.messages.first { $0.deliveryReceipt == receipt })
        for _ in 0..<2 {
            #expect(await store.checkRecoveredReply(receipt, bot: chat, row: reply))
            store.sendQueuedNextMessage()
        }
        let second = try #require(chat.messages.first { $0.content == "Second" })
        let claim = try #require(store.waitingDirectClaim(for: second))
        #expect(store.turns.nextMessages.map(\.bubble.content) == ["Second", "Third"])
        let ledger = try store.journal()
        store.runtime = RejectingRuntime(reading: ledger)
        #expect(!store.cancelQueuedSend(claim))
        #expect(store.waitingDirectClaim(for: second)?.id == claim.id && !store.canSendAsNextMessage(second))
        store.runtime = ledger

        #expect(store.recordNextMessage(claim, .submitting))
        #expect(!store.cancelQueuedSend(claim))
        #expect(try ledger.records(NextMessageRecord.self, kind: AppStore.nextMessageKind).first { $0.id == claim.id }?.state == .submitting)
        #expect(store.recordNextMessage(claim, .waiting))
        #expect(store.cancelQueuedSend(claim))
        #expect(!store.cancelQueuedSend(claim) && !store.hasWaitingTurn(in: chat))
        #expect(reply.deliveryReceipt == receipt && reply.turnState == .incomplete)
        #expect(backend.calls.all == ["send:First"] && reads.all == Array(repeating: "GET /api/history/c/p/7", count: 2))
        #expect(store.send(text: "Fresh"))
        try await backend.calls.wait { $0 == ["send:First", "send:Fresh"] }
        await backend.emit(.completed); await backend.end()
        try await waitUntil { store.isIdle(chat) }
        for _ in 0..<2 {
            let (again, saved) = reopen(url, backend)
            again.resumeRestoredNextMessages()
            #expect(again.isIdle(saved) && !again.hasWaitingTurn(in: saved))
            #expect(saved.messages.filter { again.canSendAsNextMessage($0) }.map(\.content) == ["Second", "Third"])
            #expect(saved.messages.filter { $0.content == TurnWaitCopy.cancelled }.count == 1)
            #expect(saved.messages.filter { $0.content == TurnWaitCopy.predecessorNotConfirmed }.count == 1)
            #expect(saved.messages.contains { $0.deliveryReceipt == receipt })
            #expect(backend.calls.all == ["send:First", "send:Fresh"])
        }
    }

    enum RetryClaim: CaseIterable { case retired, staleWaiting, submitting }

    @Test(arguments: RetryClaim.allCases)
    func ambiguousPredecessorHoldsThroughRelaunchAndRetry(_ claim: RetryClaim) async throws {
        let url = temporaryStore(), initial = ScriptedTurnBackend(steerless: true)
        let (original, bot) = steerStore(initial, url: url)
        #expect(original.send(text: "First"))
        try await initial.calls.wait { $0 == ["send:First"] }
        #expect(original.send(text: "Second"))
        #expect(original.send(text: "Third"))
        let second = try #require(original.turns.nextMessages.first)
        await initial.emit(.completed); await initial.end()
        try await initial.calls.wait { $0 == ["send:First", "send:Second"] }
        await initial.fail(HerdrClient.Failure.unconfirmedDelivery)
        try await waitUntil { original.isIdle(bot) }
        #expect(initial.calls.all == ["send:First", "send:Second"])
        if claim != .retired {
            second.bubble.metadata[TurnWaitCopy.key] = "waiting"
            #expect(original.recordNextMessage(second, claim == .submitting ? .submitting : .waiting))
        }
        // A separate, completed send of identical text cannot release Third.
        let unrelated = ChatMessage(role: .user, content: second.bubble.content)
        bot.messages.append(unrelated)
        bot.messages.append(ChatMessage(role: .assistant, content: "Other answer",
                                        metadata: [TurnKey.forUser: unrelated.id.uuidString], turnState: .finished))
        original.save()
        let backend = ScriptedTurnBackend()
        for _ in 0..<2 {
            let (store, chat) = reopen(url, backend)
            store.resumeRestoredNextMessages()
            store.sendQueuedNextMessage()
            #expect(store.isIdle(chat) && store.hasWaitingTurn(in: chat) && backend.calls.all.isEmpty)
            if claim == .submitting {
                let records = try store.journal().records(NextMessageRecord.self, kind: AppStore.nextMessageKind)
                #expect(records.first { $0.id == second.id }?.state == .uncertain)
            }
        }
        let (store, chat) = reopen(url, backend)
        store.resumeRestoredNextMessages()
        let reply = try #require(chat.messages.first { $0.metadata[TurnKey.forUser] == second.bubble.id.uuidString })
        store.retry(reply)
        #expect(reply.metadata[TurnKey.retry] == "confirm" && store.isIdle(chat))
        store.retry(reply)
        store.retry(reply)
        try await backend.calls.wait { $0 == ["send:Second"] }
        store.sendQueuedNextMessage()
        await backend.emit(.completed); await backend.end()
        try await backend.calls.wait { $0 == ["send:Second", "send:Third"] }
        await backend.emit(.completed); await backend.end()
        try await waitUntil { store.isIdle(chat) }
        let (again, saved) = reopen(url, backend)
        again.resumeRestoredNextMessages()
        #expect(again.isIdle(saved) && backend.calls.all == ["send:Second", "send:Third"])
    }

    enum BrokenPredecessor: CaseIterable { case legacy, missing, removed, submitting }

    @Test(arguments: BrokenPredecessor.allCases)
    func unavailablePredecessorNeverUsesANearbyAnswer(_ cause: BrokenPredecessor) async throws {
        let url = temporaryStore(), backend = ScriptedTurnBackend()
        let (writer, bot) = steerStore(backend, url: url)
        let unrelated = ChatMessage(role: .user, content: "Earlier request")
        let waiting = ChatMessage(role: .user, content: "Held", metadata: [TurnWaitCopy.key: "waiting"])
        bot.messages = [unrelated, ChatMessage(role: .assistant, content: "Done",
            metadata: [TurnKey.forUser: unrelated.id.uuidString], turnState: .finished), waiting]
        let follower = ChatMessage(role: .user, content: "Follow-up", metadata: [TurnWaitCopy.key: "waiting"])
        bot.messages.append(follower)
        let other = Bot(name: "Other")
        writer.bots.append(other)
        let ancestor = ChatMessage(role: .user, content: "Earlier queued message")
        var record = NextMessageRecord(id: UUID(), anchorID: waiting.id, kind: .turn, text: waiting.content, state: .waiting)
        if cause != .legacy { record.predecessor = .message(ancestor.id) }
        if cause == .removed || cause == .submitting {
            bot.messages.insert(ancestor, at: 0)
            if cause == .submitting { ancestor.metadata[TurnWaitCopy.key] = "waiting" }
            let prior = NextMessageRecord(id: UUID(), anchorID: ancestor.id, kind: .turn, text: ancestor.content,
                                          state: cause == .removed ? .removed : .submitting, predecessor: .independent)
            try writer.journal().put(prior, kind: AppStore.nextMessageKind, id: prior.id.uuidString)
        }
        writer.save()
        try writer.journal().put(record, kind: AppStore.nextMessageKind, id: record.id.uuidString)
        let chained = NextMessageRecord(id: UUID(), anchorID: follower.id, kind: .turn, text: follower.content,
                                        state: .waiting, predecessor: .message(waiting.id))
        try writer.journal().put(chained, kind: AppStore.nextMessageKind, id: chained.id.uuidString)
        for i in 1...2 {
            let (store, held) = reopen(url, backend)
            store.resumeRestoredNextMessages()
            #expect(store.isIdle(held) && !store.hasWaitingTurn(in: held))
            if cause == .submitting {
                let records = try store.journal().records(NextMessageRecord.self, kind: AppStore.nextMessageKind)
                #expect(records.first { $0.anchorID == ancestor.id }?.state == .uncertain)
                #expect(held.messages.filter { $0.content == ReconcileNote.uncertainQueuePrefix + ancestor.content }.count == 1)
            }
            for original in [waiting, follower] {
                let row = try #require(held.messages.first { $0.id == original.id })
                #expect(row.content == original.content && store.canSendAsNextMessage(row))
            }
            #expect(held.messages.filter { $0.content == TurnWaitCopy.predecessorNotConfirmed }.count == 2)
            #expect(store.send(text: "Fresh \(i)"))
            try await backend.calls.wait { $0.contains("send:Fresh \(i)") }
            await backend.emit(.completed); await backend.end()
            try await waitUntil { store.isIdle(held) }
            let history = store.chatHistory(held, excluding: ChatMessage(role: .assistant, content: ""))
            #expect(!history.contains { $0.content == waiting.content || $0.content == follower.content })

            let control = try #require(store.bots.first { $0.id == other.id })
            store.selectedBot = control
            #expect(store.send(text: "Control \(i)"))
            try await backend.calls.wait { $0.contains("send:Control \(i)") }
            await backend.emit(.completed); await backend.end()
            try await waitUntil { store.isIdle(control) }
        }
        #expect(backend.calls.all == ["send:Fresh 1", "send:Control 1", "send:Fresh 2", "send:Control 2"])
    }

    @Test(arguments: [false, true])
    func liveIncompleteTurnReturnsAllDependents(agentFailed: Bool) async throws {
        let url = temporaryStore(), backend = ScriptedTurnBackend(steerless: true)
        let (store, chat) = steerStore(backend, url: url)
        #expect(store.send(text: "First"))
        try await backend.calls.wait { $0 == ["send:First"] }
        #expect(store.send(text: "Second"))
        #expect(store.send(text: "Third"))
        if agentFailed {
            let receipt = HerdrDeliveryReceipt(server: HerdrServer.defaultID,
                turn: .init(core: "c", address: "p", createdMs: 7, after: 10, launched: false), text: "First")
            await backend.emit(.accepted(receipt), .failed("Agent stopped with an error"))
        }
        await backend.end()
        try await waitUntil { store.isIdle(chat) && !store.hasWaitingTurn(in: chat) }
        #expect(store.send(text: "Fresh"))
        try await backend.calls.wait { $0 == ["send:First", "send:Fresh"] }
        await backend.emit(.completed); await backend.end()
        try await waitUntil { store.isIdle(chat) }
        for _ in 0..<2 {
            let (reopened, saved) = reopen(url, backend)
            reopened.resumeRestoredNextMessages()
            #expect(saved.messages.filter { reopened.canSendAsNextMessage($0) }.map(\.content) == ["Second", "Third"])
            #expect(saved.messages.filter { $0.content == TurnWaitCopy.predecessorNotConfirmed }.count == 2)
            #expect(!reopened.hasWaitingTurn(in: saved) && backend.calls.all == ["send:First", "send:Fresh"])
        }
    }

    @Test(arguments: [false, true])
    func unresolvedReceiptReleasesFollowersOfAnUnconfirmedStop(historyGone: Bool) async throws {
        let backend = ScriptedTurnBackend(), (store, chat) = steerStore(backend)
        let http = MockHTTPProtocol.serve { _ in
            if historyGone { return (404, [:]) }
            return (200, ["items": [["id": 11, "kind": "task", "text": "Someone else's request"]]])
        }
        let server = HerdrServer(id: HerdrServer.defaultID, name: "Fixture", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: "test")
        store.herdrClientSetup = { $0.session = http.session }
        let user = ChatMessage(role: .user, content: "First")
        let reply = ChatMessage(role: .assistant, content: "", metadata: [TurnKey.forUser: user.id.uuidString,
            TurnKey.why: TurnKey.stopUnconfirmed], turnState: .stopped)
        let receipt = HerdrDeliveryReceipt(server: server.id, turn: .init(core: "c", address: "p", createdMs: 7,
            after: 10, launched: false), text: user.content)
        reply.deliveryReceipt = receipt
        let next = ChatMessage(role: .user, content: "Second")
        chat.messages = [user, reply, next]
        #expect(store.waitForTurn(next, in: chat, reason: TurnWaitCopy.afterAnswer, predecessor: .message(user.id)))
        #expect(store.send(text: "Third"))
        store.sendQueuedNextMessage()
        #expect(store.turns.nextMessages.count == 2 && backend.calls.all.isEmpty)
        #expect(await !store.checkRecoveredReply(receipt, bot: chat, row: reply))
        #expect(reply.deliveryReceipt == nil && reply.stopUnconfirmed)
        #expect(!store.hasWaitingTurn(in: chat) && backend.calls.all.isEmpty)
        #expect(chat.messages.filter { store.canSendAsNextMessage($0) }.map(\.content) == ["Second", "Third"])
    }

    @Test(arguments: [false, true])
    func lateStartupSteerRefusalReturnsItsFollowers(uncertain: Bool) async throws {
        let url = temporaryStore()
        let backend = ScriptedTurnBackend(steerFails: true, steerError: .http(uncertain ? 500 : 409, "Steer failed"))
        let (store, chat) = steerStore(backend, url: url)
        try await startSteerableTurn(store, backend, running: false)
        let turn = try #require(store.turn(in: chat))
        store.setSteerAvailable(false, token: turn.token)
        turn.awaitingSteerCapability = true
        #expect(store.send(text: "First correction"))
        #expect(store.send(text: "Second correction"))
        #expect(store.send(text: "Third correction"))
        let first = try #require(store.turns.nextMessages.first)
        await backend.holdSteers()
        store.setSteerAvailable(true, token: turn.token)
        store.deliverStartupFollowUps(to: chat, turn: turn)
        try await backend.calls.wait { $0.contains("steer-held:First correction") }
        await backend.emit(.completed); await backend.end()
        try await waitUntil { store.isIdle(chat) }
        #expect(store.hasWaitingTurn(in: chat))
        await backend.releaseSteers()
        try await waitUntil { !store.hasWaitingTurn(in: chat) }
        let calls = ["send:go", "steer-held:First correction", "steer-failed:First correction"]
        #expect(backend.calls.all == calls)
        for _ in 0..<2 {
            let (again, saved) = reopen(url, backend)
            again.resumeRestoredNextMessages()
            let records = try again.journal().records(NextMessageRecord.self, kind: AppStore.nextMessageKind)
            #expect(records.first { $0.id == first.id }?.state == (uncertain ? .uncertain : .removed))
            #expect(saved.messages.filter { $0.content == TurnWaitCopy.predecessorNotConfirmed }.count == 2)
            #expect(!again.hasWaitingTurn(in: saved) && backend.calls.all == calls)
        }
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
