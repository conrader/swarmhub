import Foundation
import Testing
@testable import AgentApp

@MainActor struct TranscriptOrderTests {
    @Test func textOnlySteerSurvivesFinalSnapshotReloadAndRepeatedHistoryPages() async throws {
        let url = temporaryStore()
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend, url: url)
        let noon = Date(timeIntervalSince1970: 43_200)
        let serverID = HerdrServer.defaultID
        let id = bot.id.uuidString.lowercased()
        let http = MockHTTPProtocol.serve { request in
            switch request.url?.path {
            case "/api/workspace": return (200, ["core": "fixture", "agents": [], "templates": []])
            case "/api/bots": return (200, ["bots": []])
            case "/api/bots/history":
                let entries: [[String: Any]] = [
                    ["id": 1, "bot": id, "kind": "said", "journal": 80, "text": "Yesterday", "at_ms": 1_000, "unread": false, "notify": false],
                    ["id": 2, "bot": id, "kind": "message", "text": "FYI", "at_ms": 43_890_000, "unread": false, "notify": false],
                    ["id": 3, "bot": id, "kind": "said", "code": "direct_followup", "journal": 90, "text": "Answer B", "at_ms": 43_920_000, "unread": false, "notify": false]]
                return (200, ["items": request.url?.query?.hasPrefix("after=0&") == true ? entries : [], "more": false])
            default: return (404, [:])
            }
        }
        let server = HerdrServer(id: serverID, name: "Fixture", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: "fixture")
        store.herdrClientSetup = { $0.session = http.session }
        store.now = { noon }
        #expect(store.send(text: "Question A"))
        try await waitUntil { store.canSteer(in: bot) }
        let placeholder = try #require(bot.messages.last)
        #expect(placeholder.isStreaming && placeholder.content.isEmpty && placeholder.createdAt == noon)
        store.now = { noon.addingTimeInterval(660) }
        #expect(store.send(text: "Question B"))
        let steer = try #require(bot.messages.last)
        try await waitUntil { steer.metadata[SteerKey.steer] == "delivered" }
        // A page can import FYIs while its 'said' entries wait for the stream's journal IDs.
        store.selectedBot = nil
        await store.syncTeam(server)
        #expect(bot.messages.map(\.content) == ["Question A", "", "Question B", "FYI"])
        store.now = { noon.addingTimeInterval(720) }
        await backend.emit(.replace("Answer"))
        try await waitUntil { placeholder.content == "Answer" }
        #expect(bot.messages.filter { !$0.isSilent }.map(\.content) == ["Question A", "Question B", "FYI", "Answer"])
        #expect(bot.messages.last === placeholder && placeholder.isStreaming)

        await backend.emit(.journal(serverID, [90]), .replace("Answer B"), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(bot) }
        let ids = bot.messages.map(\.id)
        #expect(bot.messages.map(\.content) == ["Question A", "Question B", "FYI", "Answer B"])
        #expect(placeholder.turnState == .finished && placeholder.transcriptDate > steer.createdAt)
        #expect(store.herdrTriggers(of: placeholder, in: bot).map(\.id) == [ids[0]])
        #expect(await backend.calls.all == ["send:Question A", "steer:Question B"])

        let reopened = AppStore(storeURL: url, autoStart: false, keyStore: store.keyStore, defaults: store.defaults)
        reopened.herdrClientSetup = { $0.session = http.session }
        reopened.selectedBot = nil
        let saved = try #require(reopened.bots.first { $0.id == bot.id })
        #expect(saved.messages.map(\.id) == ids)
        await reopened.syncTeam(server)
        let mergedIDs = saved.messages.map(\.id)
        let expected = ["Yesterday", "Question A", "Question B", "FYI", "Answer B"]
        #expect(saved.messages.map(\.content) == expected)
        #expect(Array(mergedIDs.dropFirst()) == ids)
        reopened.defaults.removeObject(forKey: "herdrTeamCursor.\(serverID)")
        await reopened.syncTeam(server)
        #expect(saved.messages.map(\.id) == mergedIDs)
        let disk = try #require(StoreFile.decode(Data(contentsOf: url)).bots.first { $0.id == bot.id })
        #expect(disk.messages.map(\.id) == mergedIDs && disk.messages.map(\.content) == expected)
    }

    @Test(arguments: [true, false]) func groupKeepsEarlierPartsAcrossTokensCumulativeSnapshotsAndTwoReceipts(aggregateDraft: Bool) async throws {
        let url = temporaryStore(), backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend, url: url)
        let other = Bot(name: "Other", backend: .herdr)
        store.bots.append(other)
        let group = try #require(store.createGroup(name: "Fixture", memberIDs: [bot.id, other.id]))
        #expect(store.send(text: "@Steer question A", to: group))
        try await waitUntil { store.canSteer(in: group) }
        await backend.emit(.token("First."))
        let original = try #require(group.messages.last)
        try await waitUntil { original.content == "First." }
        #expect(store.send(text: "Question B", to: group))
        let steerB = try #require(group.messages.last)
        try await waitUntil { steerB.metadata[SteerKey.steer] == "delivered" }
        let unrelated = ChatMessage(role: .assistant, content: "Independent reply", authorID: other.id)
        group.messages.append(unrelated)
        await backend.emit(.replace("First."), .replace(aggregateDraft ? "First.\n\nSecond." : "Second."))
        try await waitUntil { group.messages.last?.content == "Second." }
        let second = try #require(group.messages.last)
        #expect(group.messages.suffix(4).map(\.id) == [original.id, steerB.id, unrelated.id, second.id])
        #expect(store.send(text: "Question C", to: group))
        let steerC = try #require(group.messages.last)
        try await waitUntil { steerC.metadata[SteerKey.steer] == "delivered" }
        await backend.emit(.replace("First.\n\nSecond."), .status(TurnErrorCopy.reconnecting))
        try await waitUntil { store.turn(in: group)?.assistant?.metadata[TurnKey.reconnecting] == "1" }
        #expect(group.messages.last === steerC && second.isStreaming, "a cumulative replay adds no new row")
        await backend.emit(.token("Third."), .journal("fixture", [1, 2]), .replace("First.\n\nSecond.Third."), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(group) }
        let expected = ["@Steer question A", "First.", "Question B", "Independent reply", "Second.", "Question C", "Third."]
        #expect(group.messages.filter { !$0.isSilent }.map(\.content) == expected)
        #expect(group.messages.last?.authorID == bot.id && group.messages.last?.metadata[TurnKey.forUser] == group.messages.first?.id.uuidString)
        let saved = try #require(StoreFile.decode(Data(contentsOf: url)).groups.first)
        #expect(saved.messages.map(\.id) == group.messages.map(\.id) && saved.messages.map(\.content) == expected)
    }

    @Test func oldStoreRepairsTaggedImportsAndPreservesAmbiguousLocalReplies() throws {
        func row(_ role: MessageRole, _ text: String, _ seconds: Double, _ metadata: [String: String] = [:]) -> ChatMessage {
            ChatMessage(role: role, content: text, createdAt: Date(timeIntervalSince1970: seconds), metadata: metadata)
        }
        let rows = [row(.user, "A", 10), row(.assistant, "Possibly visible before B", 10),
                    row(.user, "B", 20, ["steer": "delivered"]), row(.user, "C", 21, ["steer": "failed"]),
                    row(.user, "D", 22, ["steer": "queued"]),
                    row(.assistant, "Unrelated", 1, ["herdrTeamEntry": "fixture:1"]),
                    row(.system, "FYI", 15, ["herdrTeamEntry": "fixture:2"])]
        let data = try JSONEncoder().encode([Bot(name: "Legacy", messages: rows)])
        let restored = try StoreFile.decode(data)
        let expected = [5, 0, 1, 6, 2, 3, 4].map { rows[$0].id }
        #expect(restored.bots.first?.messages.map(\.id) == expected)
        #expect(try StoreFile.decode(JSONEncoder().encode(restored)).bots.first?.messages.map(\.id) == expected)
    }
}
