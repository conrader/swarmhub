import Foundation
import Testing
@testable import AgentApp

@MainActor struct RecoveredReplyTests {
    private let receipt = HerdrDeliveryReceipt(server: HerdrServer.defaultID,
        turn: .init(core: "core", address: "terminal", createdMs: 50, after: 6, launched: false), text: "first")

    enum SavedTurn: CaseIterable { case interrupted, legacyFailedStop, quitDuringStop }

    @Test(arguments: SavedTurn.allCases) func readsOlderPagesIntoOriginalRowAcrossRestart(savedTurn: SavedTurn) async throws {
        let url = temporaryStore()
        let (store, bot) = steerStore(ScriptedTurnBackend(), url: url)
        let http = MockHTTPProtocol.serve { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/history/core/terminal/50" else {
                return (400, [:])
            }
            if request.url?.query == "before=10" {
                return (200, ["items": [["id": 7, "kind": "task", "text": "first"], ["id": 8, "kind": "artifact", "detail": "view.png"],
                                        ["id": 9, "kind": "reply", "text": "finished", "codex_model": "model-z", "codex_rerouted": true]]])
            }
            return (200, ["before": 10, "items": [["id": 10, "kind": "task", "text": "other"],
                                                  ["id": 11, "kind": "reply", "text": "wrong answer"]]])
        }
        store.saveHerdrServer(HerdrServer(id: receipt.server, name: "Fixture", kind: .address, address: "http://\(http.host)"), token: "test")
        let question = ChatMessage(role: .user, content: "first")
        let row = ChatMessage(role: .assistant, content: "draft", metadata: [TurnKey.forUser: question.id.uuidString], turnState: .incomplete)
        row.deliveryReceipt = receipt
        bot.messages = [question, row]
        if savedTurn == .quitDuringStop {
            row.turnState = .stopped
            row.metadata[TurnKey.why] = TurnKey.stopPending
        } else if savedTurn == .legacyFailedStop {
            row.turnState = .stopped
            row.metadata[TurnKey.why] = "stopped"
            bot.messages.append(ChatMessage(role: .system, content: IntentLine.stopFailed.render("Herdr", "Could not connect to the server.")))
        }
        store.save()
        let reopened = AppStore(storeURL: url, autoStart: false, keyStore: store.keyStore, defaults: store.defaults)
        reopened.herdrClientSetup = { $0.session = http.session }
        let saved = try #require(reopened.bots.first { $0.id == bot.id })
        let answer = try #require(saved.messages.first { $0.id == row.id })
        #expect(answer.stopUnconfirmed == (savedTurn != .interrupted))
        reopened.selectedBot = nil
        #expect(answer.deliveryReceipt == receipt)
        #expect(await !reopened.checkRecoveredReply(receipt, bot: saved, row: answer))
        #expect(await !reopened.checkRecoveredReply(receipt, bot: saved, row: answer))
        let disk = try #require(StoreFile.decode(Data(contentsOf: url)).bots.first { $0.id == bot.id })
        #expect(disk.unreadCount == 1)
        #expect(disk.messages.map(\.id) == bot.messages.map(\.id))
        let result = try #require(disk.messages.first { $0.id == row.id })
        #expect(result.runSummary?.line == "Routed to model-z")
        #expect(result.content == "finished" && result.turnState == .finished && result.deliveryReceipt == nil)
        #expect(result.metadata["herdrJournal"] == "\(receipt.server):9")
        #expect(result.publishedResults?.items.map(\.title) == ["view.png"])
    }

    @Test func failedGroupStopUsesOnlyTheOriginalMemberAndChat() async throws {
        let (store, bot) = steerStore(ScriptedTurnBackend())
        let group = GroupChat(name: "Release", memberIDs: [bot.id])
        let row = ChatMessage(role: .assistant, content: "Building", metadata: [TurnKey.why: TurnKey.stopUnconfirmed],
                              authorID: bot.id, turnState: .stopped)
        row.deliveryReceipt = receipt
        group.messages = [row]
        let http = MockHTTPProtocol.serve { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/history/core/terminal/50" else { return (400, [:]) }
            return (200, ["items": [["id": 7, "kind": "task", "text": "first"], ["id": 8, "kind": "reply", "text": "Built"]]])
        }
        store.saveHerdrServer(HerdrServer(id: receipt.server, name: "Fixture", kind: .address, address: "http://\(http.host)"), token: "test")
        store.herdrClientSetup = { $0.session = http.session }
        #expect(await !store.checkRecoveredReply(receipt, bot: bot, row: row, group: group))
        #expect(row.stopUnconfirmed && row.deliveryReceipt == receipt)
        store.groups = [group]
        group.memberIDs = []
        #expect(await !store.checkRecoveredReply(receipt, bot: bot, row: row, group: group))
        #expect(row.content == "Building")
        group.memberIDs = [bot.id]
        row.metadata[TurnKey.why] = "stopped"
        #expect(await !store.checkRecoveredReply(receipt, bot: bot, row: row, group: group))
        #expect(row.content == "Building")
        row.metadata[TurnKey.why] = TurnKey.stopUnconfirmed
        #expect(await !store.checkRecoveredReply(receipt, bot: bot, row: row, group: group))
        #expect(row.turnState == .finished && row.content == "Built" && row.authorID == bot.id && row.deliveryReceipt == nil)
        #expect(group.messages.count == 1 && group.unreadCount == 1 && bot.unreadCount == 0)
    }

    enum QuitPoint: CaseIterable { case beforeOutput, afterCommentary, afterSplit }

    @Test(arguments: QuitPoint.allCases) func confirmedGuidanceRestoresBeforeLaterQuestions(at quit: QuitPoint) async throws {
        let url = temporaryStore()
        let (store, bot) = steerStore(ScriptedTurnBackend(), url: url)
        let question = ChatMessage(role: .user, content: "first")
        let prefix = quit == .afterCommentary ? "Bl" : "Before the correction."
        let original = ChatMessage(role: .assistant, content: quit == .beforeOutput ? "" : prefix,
            metadata: [TurnKey.forUser: question.id.uuidString], turnState: .incomplete)
        original.deliveryReceipt = receipt
        let first = ChatMessage(role: .user, content: "use red", metadata: [SteerKey.steer: "delivered"])
        let latest = ChatMessage(role: .user, content: "use blue", metadata: [SteerKey.steer: "delivered"])
        let separate = ChatMessage(role: .user, content: "new task")
        let other = ChatMessage(role: .user, content: "other guidance", metadata: [SteerKey.steer: "delivered"])
        var rows = [question, original, first, latest]
        let pending: ChatMessage
        if quit == .afterSplit {
            pending = store.replyPartAfterGuidance(original, origin: original.id.uuidString, at: .now)
            pending.content = "Partial"
            rows.append(pending)
            #expect(original.deliveryReceipt == nil && pending.deliveryReceipt == receipt)
        } else { pending = original }
        bot.messages = rows + [separate, other]
        let final = quit == .afterSplit ? prefix + "\n\nBlue" : "Blue"
        let http = MockHTTPProtocol.serve { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/history/core/terminal/50" else { return (400, [:]) }
            return (200, ["items": [["id": 7, "kind": "task", "text": "first"], ["id": 8, "kind": "reply", "text": final]]])
        }
        store.saveHerdrServer(HerdrServer(id: receipt.server, name: "Fixture", kind: .address, address: "http://\(http.host)"), token: "test")
        store.save()
        let reopened = AppStore(storeURL: url, autoStart: false, keyStore: store.keyStore, defaults: store.defaults)
        reopened.herdrClientSetup = { $0.session = http.session }
        let saved = try #require(reopened.bots.first { $0.id == bot.id })
        let restored = try #require(saved.messages.first { $0.id == pending.id })
        #expect(await !reopened.checkRecoveredReply(receipt, bot: saved, row: restored))
        let disk = try #require(StoreFile.decode(Data(contentsOf: url)).bots.first { $0.id == bot.id })
        #expect(saved.messages.allSatisfy { !$0.isStreaming })
        let i = try #require(disk.messages.firstIndex { $0.id == latest.id })
        let answer = disk.messages[i + 1]
        #expect(answer.content == "Blue" && answer.turnState == .finished && answer.deliveryReceipt == nil)
        #expect(disk.messages[i + 2].id == separate.id && disk.messages.last?.id == other.id)
        #expect(disk.messages.allSatisfy { $0.turnState != .incomplete })
        if quit == .beforeOutput {
            #expect(answer.id == original.id && disk.messages.count == 6)
        } else {
            #expect(disk.messages[1].id == original.id && disk.messages[1].content == prefix && disk.messages.count == 7)
            #expect(TurnReplyText.complete(answer, in: disk) == prefix + "\n\nBlue")
            if quit == .afterSplit { #expect(answer.id == pending.id) }
        }
    }

    @Test func aLaterTaskCannotSupplyTheAnswer() {
        let first = HerdrClient.Item(id: 7, kind: "task", text: "first")
        let second = HerdrClient.Item(id: 8, kind: "task", text: "second")
        let reply = HerdrClient.Item(id: 9, kind: "reply", text: "other reply")
        let duplicate = HerdrClient.Item(id: 10, kind: "task", text: "first")
        for rows in [[second, reply], [first, second, reply], [first, reply, duplicate]] {
            guard case .unresolved = receipt.resolve(rows) else { Issue.record("Attributed a different task"); return }
        }
        var threaded = reply
        threaded.answerTo = .init(id: second.id)
        guard case .waiting = receipt.resolve([first, threaded]) else { Issue.record("Adopted a thread reply"); return }
    }
}
