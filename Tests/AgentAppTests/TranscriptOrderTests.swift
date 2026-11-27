import Foundation
import Testing
@testable import AgentApp

@MainActor struct TranscriptOrderTests {
    @Test func separateFollowupsAndQueuedAnswersHaveTheirOwnHeading() {
        let first = ChatMessage(role: .assistant, content: "Checking", metadata: [TurnKey.forUser: "first"])
        let fragment = ChatMessage(role: .assistant, content: "Still checking", metadata: [TurnKey.forUser: "first"])
        let notice = ChatMessage(role: .system, content: "Team activity")
        let followup = ChatMessage(role: .assistant, content: "Both helpers finished", metadata: ["herdrTeamEntry": "local:2"])
        let queued = ChatMessage(role: .assistant, content: "Next request", metadata: [TurnKey.forUser: "second"])
        #expect(ChatView.openers([first, fragment, notice, followup, queued]) == [first.id, followup.id, queued.id])
        #expect(ChatView.openers([first, notice, fragment].dropFirst()) == [fragment.id])
    }

    @Test(arguments: [-3_600_000, 3_600_000]) func textOnlySteerSurvivesFinalSnapshotReloadAndRepeatedHistoryPages(clockSkew: Int) async throws {
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
                    ["id": 1, "bot": id, "kind": "said", "journal": 80, "text": "Yesterday", "at_ms": 1_000 + clockSkew, "unread": false, "notify": false],
                    ["id": 2, "bot": id, "kind": "message", "text": "FYI", "at_ms": 43_890_000 + clockSkew, "unread": false, "notify": false],
                    ["id": 3, "bot": id, "kind": "said", "code": "direct_followup", "journal": 90, "text": "Answer B", "at_ms": 43_920_000 + clockSkew, "unread": false, "notify": false]]
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
        let selection = MessageSelection()
        let picked = bot.messages
        selection.show(rows: picked) { store.copiedMessage($0, botName: bot.name) }
        for message in picked { selection.toggle(message.id) }
        #expect(selection.copiedText.components(separatedBy: "\n\n").map { $0.components(separatedBy: "\n").last ?? "" } == ["Question A", "Question B", "FYI", "Answer B"])
        #expect(store.copiedMessage(placeholder, botName: bot.name).date == placeholder.continuedAt)
        #expect(placeholder.turnState == .finished && placeholder.transcriptDate > steer.createdAt)
        #expect(store.herdrTriggers(of: placeholder, in: bot).map(\.id) == [ids[0]])
        #expect(backend.calls.all == ["send:Question A", "steer:Question B"])

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

    @Test func steeringDuringAPolishSentenceKeepsTheAnswerTogether() async throws {
        let (store, bot) = steerStore(ScriptedTurnBackend())
        let draft = ChatMessage(role: .assistant, content: "Tak. Jeśli M1", isStreaming: true)
        let exchange = ChatMessage(role: .system, content: "Team exchange")
        let steer = ChatMessage(role: .user, content: "Sprawdź M1", metadata: [SteerKey.steer: "delivered"])
        bot.messages = [draft, exchange, steer]
        store.turns.steers[draft.id] = PendingSteer(conversation: bot, bubbles: [steer])
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let answer = "Tak. Jeśli M1 działa w chwili zaniku prądu, powinien się włączyć."
        pair.continuation.yield(.replace(answer))
        pair.continuation.yield(.journal("qa", [22]))
        pair.continuation.yield(.replace(answer))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        _ = try await store.consumeTurn(pair.stream, assistant: draft, bot: bot, cumulativeReplacements: true)
        #expect(bot.messages.map(\.content) == ["Team exchange", "Sprawdź M1", answer])
        #expect(bot.messages.filter { $0.role == .assistant }.map(\.content).joined() == answer)
        #expect(bot.messages.contains { $0 === exchange })
    }

    @Test func reopeningALegacySplitPreservesTextAndToolOwnership() throws {
        let (store, bot) = steerStore(ScriptedTurnBackend())
        let prefix = "Tak. Jeśli M1", suffix = " działa po przerwie."
        let first = ChatMessage(role: .assistant, content: prefix)
        let id = first.id.uuidString
        first.metadata = [TurnReplyText.origin: id, TurnKey.part: "1"]
        var steps = ToolActivity()
        steps.apply(.init(phase: .started, name: "Command"), at: .now, textOffset: 201)
        first.activity = steps
        let next = ChatMessage(role: .assistant, content: suffix, metadata: [TurnReplyText.origin: id, TurnKey.part: "2"])
        var later = ToolActivity()
        later.apply(.init(phase: .started, name: "Read"), at: .now, textOffset: 5)
        next.activity = later
        bot.messages = [first, ChatMessage(role: .system, content: "Exchange"), ChatMessage(role: .user, content: "Steer"), next]
        let bytes = try JSONEncoder().encode(StoreFile(bots: [bot], groups: []))
        let rows = try #require(StoreFile.decode(bytes).bots.first?.messages)
        #expect(rows.map(\.id) == bot.messages.map(\.id))
        #expect(rows.map(\.content) == ["", "Exchange", "Steer", prefix + suffix])
        #expect(rows.first?.activity?.total == 1)
        #expect(rows.last?.activity?.steps.first?.textOffset == prefix.utf16.count + 5)
        TurnReplyText.repairSavedSteerCuts(rows)
        #expect(rows.last?.content == prefix + suffix)
        _ = store
    }

    @Test func lateFollowupPrecedesTheNextQuestionAndAnswer() {
        let question = ChatMessage(role: .user, content: "Next question")
        let answer = ChatMessage(role: .assistant, content: "Next answer",
            metadata: [TurnKey.forUser: question.id.uuidString, "herdrJournal": "s:30"])
        var rows = [ChatMessage(role: .assistant, content: "First answer", metadata: ["herdrJournal": "s:10"]),
                    question, answer]
        let followup = ChatMessage(role: .assistant, content: "Earlier follow-up")
        TranscriptHistory.insert(followup, into: &rows, server: "s", entry: 2, followup: true, journal: 20, receivedAt: .now)
        #expect(rows.map(\.content) == ["First answer", "Earlier follow-up", "Next question", "Next answer"])
    }

    @Test func cumulativeCorrectionAtAReceiptUpdatesTheEarlierParagraph() async throws {
        let (store, bot) = steerStore(ScriptedTurnBackend())
        let stale = ChatMessage(role: .user, content: "Older wait", metadata: [TurnWaitCopy.key: "waiting"])
        let draft = ChatMessage(role: .assistant, content: "First draft.", isStreaming: true)
        let followup = ChatMessage(role: .user, content: "More?", metadata: [SteerKey.steer: "delivered"])
        let queued = ChatMessage(role: .user, content: "Next question", metadata: [TurnWaitCopy.key: "waiting"])
        bot.messages = [stale, draft, followup, queued]
        store.turns.steers[draft.id] = PendingSteer(conversation: bot, bubbles: [followup])
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        pair.continuation.yield(.replace("Revised first.\n\nSecond paragraph."))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        _ = try await store.consumeTurn(pair.stream, assistant: draft, bot: bot, cumulativeReplacements: true)
        #expect(bot.messages.map(\.content) == ["Older wait", "Revised first.", "More?", "Second paragraph.", "Next question"])
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
        let otherQuestion = ChatMessage(role: .user, content: "@Other independent question")
        group.messages.append(contentsOf: [otherQuestion, unrelated])
        await backend.emit(.replace("First."), .replace(aggregateDraft ? "First.\n\nSecond." : "Second."))
        try await waitUntil { group.messages.last?.content == "Second." }
        let second = try #require(group.messages.last)
        let actualIDs: [UUID] = group.messages.suffix(5).map(\.id)
        let expectedIDs: [UUID] = [original.id, steerB.id, otherQuestion.id, unrelated.id, second.id]
        #expect(actualIDs == expectedIDs)
        #expect(store.send(text: "Question C", to: group))
        let steerC = try #require(group.messages.last)
        try await waitUntil { steerC.metadata[SteerKey.steer] == "delivered" }
        await backend.emit(.replace("First.\n\nSecond."), .replace("First."), .status(TurnErrorCopy.reconnecting))
        try await waitUntil { store.turn(in: group)?.assistant?.metadata[TurnKey.reconnecting] == "1" }
        #expect(group.messages.last === steerC && second.isStreaming && second.content == "Second.", "a cumulative replay adds no new row")
        await backend.emit(.token("Third."))
        if !aggregateDraft { await backend.emit(.replace("Second.Third.")) }
        await backend.emit(.journal("fixture", [1, 2]), .replace("First.\n\nSecond.Third."), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(group) }
        let expected = ["@Steer question A", "First.", "Question B", "@Other independent question", "Independent reply", "Second.", "Question C", "Third."]
        #expect(group.messages.filter { !$0.isSilent }.map(\.content) == expected)
        #expect(group.messages.last?.authorID == bot.id && group.messages.last?.metadata[TurnKey.forUser] == group.messages.first?.id.uuidString)
        let saved = try #require(StoreFile.decode(Data(contentsOf: url)).groups.first)
        #expect(saved.messages.map(\.id) == group.messages.map(\.id) && saved.messages.map(\.content) == expected)
        #expect(store.send(text: "@Steer next", to: group))
        try await backend.calls.wait { $0.contains { $0.contains("@Steer next") } }
        let context = try #require(backend.calls.all.last)
        #expect(context.contains("@Other independent question") && context.contains("Other: Independent reply"))
        #expect(!context.contains("Steer: Second.") && !context.contains("Question C"))
        await backend.emit(.completed); await backend.end()
        try await waitUntil { store.isIdle(group) }
    }

    @Test func correctedJournalUpdatesEarlierPartsWithoutRepeatingTheDraft() async throws {
        let url = temporaryStore(), backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend, url: url)
        try await startSteerableTurn(store, backend, running: false)
        #expect(store.send(text: "Question B"))
        try await waitUntil { bot.messages.last?.metadata[SteerKey.steer] == "delivered" }
        await backend.emit(.replace("Before.\n\nAnswer B"))
        try await waitUntil { bot.messages.last?.content == "Answer B" }
        #expect(bot.messages.map(\.content) == ["go", "Before.", "Question B", "Answer B"])
        await backend.emit(.journal("fixture", [10, 11]), .replace("Revised first paragraph.\n\nAnswer B"), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(bot) }
        let expected = ["go", "Revised first paragraph.", "Question B", "Answer B"]
        #expect(bot.messages.map(\.content) == expected)
        let saved = try #require(StoreFile.decode(Data(contentsOf: url)).bots.first)
        #expect(saved.messages.map(\.content) == expected && saved.messages[1].metadata["herdrJournal"] == "fixture:10 fixture:11")
    }

    @Test func lateReceiptAndOneCharacterFinalEditKeepOneReply() async throws {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend)
        #expect(store.send(text: "A"))
        try await waitUntil { store.canSteer(in: bot) }
        await backend.holdSteers()
        #expect(store.send(text: "B"))
        try await backend.calls.wait { $0.contains("steer-held:B") }
        await backend.emit(.replace("Already visible"))
        try await waitUntil { bot.messages[1].content == "Already visible" }
        await backend.releaseSteers()
        try await waitUntil { bot.messages.last?.metadata[SteerKey.steer] == "delivered" }
        await backend.emit(.replace("Already visible."), .journal("fixture", [10]), .replace("Already visible."), .completed)
        await backend.end()
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.messages.map(\.content) == ["A", "Already visible.", "B"])
        #expect(bot.messages[1].metadata["herdrJournal"] == "fixture:10")
    }

    @Test(arguments: [true, false]) func completedTurnDeliversFencedMessageExactlyOnce(steerInsideBlock: Bool) async throws {
        let backend = ScriptedTurnBackend()
        let (store, bot) = steerStore(backend)
        let peer = Bot(name: "Peer", backend: .herdr)
        store.bots.append(peer)
        let opening = "```swarmhub\n" + #"{"op":"message_bot","to":"Peer","message":"#
        let closing = #""Please check."}"# + "\n```\n"
        let block = opening + closing
        let draft = steerInsideBlock ? opening : block
        #expect(store.send(text: "A"))
        try await waitUntil { store.canSteer(in: bot) }
        await backend.emit(.token(draft))
        try await waitUntil { bot.messages[1].content == draft }
        #expect(store.send(text: "B"))
        try await waitUntil { bot.messages.last?.metadata[SteerKey.steer] == "delivered" }
        await backend.emit(.token((steerInsideBlock ? closing : "") + "Answer B."), .completed)
        await backend.end(stream: 1)
        let delivery = "send:" + HerdrBotRelay.message(from: bot.name, "Please check.")
        try await backend.calls.wait { $0.contains(delivery) }
        #expect(backend.calls.all == ["send:A", "steer:B", delivery])
        #expect(bot.messages.filter { $0.role != .system }.map(\.content) == ["A", block, "B", "Answer B."])
        #expect(peer.messages.filter { $0.metadata[HerdrBotRelay.Key.kind] == HerdrBotRelay.message }.count == 1)
        await backend.emit(.failed("Fixture ended"), stream: 2); await backend.end(stream: 2)
        try await waitUntil { store.isIdle(peer) }
    }

    @Test func reopenedMultipartReplyOffersItsStructuredRequestsOnce() throws {
        let url = temporaryStore()
        let (store, bot) = steerStore(ScriptedTurnBackend(), url: url)
        store.setCanManageBots(bot, true)
        let trigger = ChatMessage(role: .user, content: "Propose changes")
        let block = """
        ```swarmhub
        [{"op":"create_bot","name":"Scout"},{"op":"set_model","bots":"all","model":"fixture"},
        """
        bot.messages = [
            trigger,
            ChatMessage(role: .assistant, content: block, metadata: [TurnKey.forUser: trigger.id.uuidString, TurnKey.part: "1"], turnState: .finished),
            ChatMessage(role: .user, content: "Continue", metadata: [SteerKey.steer: "delivered"]),
            ChatMessage(role: .assistant, content: "\n" + #"{"op":"about_you","add":"Uses metric."}]"# + "\n```",
                        metadata: [TurnKey.forUser: trigger.id.uuidString, TurnKey.part: "2"], turnState: .finished)
        ]
        store.save()
        let reopened = AppStore(storeURL: url, autoStart: false, keyStore: store.keyStore, defaults: store.defaults)
        let main = try #require(reopened.bots.first)
        let requests = reopened.pendingHerdrBots(for: main)
        #expect(requests.map(\.request.name) == ["Scout"])
        #expect(reopened.pendingHerdrModels(for: main).map(\.request.model) == ["fixture"])
        #expect(reopened.pendingAboutYou(for: main).map(\.text) == ["Uses metric."])
        reopened.dismissHerdrBot(try #require(requests.first), manager: main)
        #expect(reopened.pendingHerdrBots(for: main).isEmpty)
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
