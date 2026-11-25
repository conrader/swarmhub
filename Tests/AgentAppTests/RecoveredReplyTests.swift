import Foundation
import Testing
@testable import AgentApp

@MainActor struct RecoveredReplyTests {
    private let receipt = HerdrDeliveryReceipt(server: HerdrServer.defaultID,
        turn: .init(core: "core", address: "terminal", createdMs: 50, after: 6, launched: false), text: "first")

    @Test func readsOlderPagesIntoOriginalRowAcrossRestart() async throws {
        let url = temporaryStore()
        let (store, bot) = steerStore(ScriptedTurnBackend(), url: url)
        let http = MockHTTPProtocol.serve { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/history/core/terminal/50" else {
                return (400, [:])
            }
            if request.url?.query == "before=10" {
                return (200, ["items": [["id": 7, "kind": "task", "text": "first"], ["id": 8, "kind": "artifact", "detail": "view.png"],
                                        ["id": 9, "kind": "reply", "text": "finished"]]])
            }
            return (200, ["before": 10, "items": [["id": 10, "kind": "task", "text": "other"],
                                                  ["id": 11, "kind": "reply", "text": "wrong answer"]]])
        }
        store.saveHerdrServer(HerdrServer(id: receipt.server, name: "Fixture", kind: .address, address: "http://\(http.host)"), token: "test")
        let question = ChatMessage(role: .user, content: "first")
        let row = ChatMessage(role: .assistant, content: "draft", metadata: [TurnKey.forUser: question.id.uuidString], turnState: .incomplete)
        row.deliveryReceipt = receipt
        bot.messages = [question, row]
        store.save()
        let reopened = AppStore(storeURL: url, autoStart: false, keyStore: store.keyStore, defaults: store.defaults)
        reopened.herdrClientSetup = { $0.session = http.session }
        let saved = try #require(reopened.bots.first { $0.id == bot.id })
        let answer = try #require(saved.messages.last)
        #expect(answer.deliveryReceipt == receipt)
        #expect(await !reopened.checkRecoveredReply(receipt, bot: saved, row: answer))
        #expect(await !reopened.checkRecoveredReply(receipt, bot: saved, row: answer))
        let disk = try #require(StoreFile.decode(Data(contentsOf: url)).bots.first { $0.id == bot.id })
        #expect(disk.messages.map(\.id) == [question.id, row.id])
        let result = try #require(disk.messages.last)
        #expect(result.content == "finished" && result.turnState == .finished && result.deliveryReceipt == nil)
        #expect(result.metadata["herdrJournal"] == "\(receipt.server):9")
        #expect(result.publishedResults?.items.map(\.title) == ["view.png"])
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
