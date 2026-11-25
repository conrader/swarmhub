import Foundation
import Testing
@testable import AgentApp

@MainActor struct HistoricalChoiceTests {
    /// Version-one stores can lack metadata, presentation, and a turn state on every row.
    @Test(arguments: ["fence", "marker", "inferred"])
    func answerFromStoredHistorySurvivesAnotherReopen(_ form: String) async throws {
        let question = "Should I include the appendix?"
        let content: String
        switch form {
        case "fence": content = "```choices\n\(question)\n- Yes\n- No\n```"
        case "marker": content = "\(question)\n<!-- choices -->\n1. Yes\n2. No"
        default: content = question
        }
        let url = temporaryStore(), botID = UUID(), sourceID = UUID()
        let rows: [[String: Any]] = [
            ["id": sourceID.uuidString, "role": "assistant", "content": content, "createdAt": 1],
            ["id": UUID().uuidString, "role": "user", "content": "Yes", "createdAt": 2],
            ["id": UUID().uuidString, "role": "assistant", "content": "Should I shorten the title?", "createdAt": 3],
        ]
        let legacy: [[String: Any]] = [["id": botID.uuidString, "name": "Editor", "backend": "Mock", "messages": rows]]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let backend = GroupBackend(name: "Editor")
        func reopen() -> AppStore {
            AppStore(storeURL: url, autoStart: false, backendFactory: { _ in backend },
                     keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        }
        let target = ConversationActionTarget.bot(botID: botID)
        let key: String
        switch form {
        case "inferred": key = ChatChoiceInference.answerKey
        case "marker": key = "picked.1"
        default: key = "picked.0"
        }
        func click(_ store: AppStore, source: ChatMessage) throws -> Bool {
            if form == "inferred" {
                return store.answerInferredChoice(target: target, source: source, shownContent: content, answer: .option("No"))
            }
            let blocks = ChatCardParser.parseVisibleReply(content)
            let block = try #require(blocks.last)
            return store.performCardAction(target: target, sourceID: source.id, index: blocks.count - 1,
                                           expected: block, choice: .option("No"), shownContent: content)
        }
        let store = reopen()
        let bot = try #require(store.bots.first), source = try #require(bot.messages.first)
        #expect(source.turnState == nil && source.metadata.isEmpty)
        #expect(store.choiceStatus(source, target: target, key: key, binary: true).enabled)
        #expect(try click(store, source: source))
        try await waitUntil { !store.anyTurnRunning }
        let restored = reopen()
        let chat = try #require(restored.bots.first), original = try #require(chat.messages.first)
        let reply = try #require(chat.messages.first { $0.replyToID == sourceID })
        #expect(reply.content == "No" && reply.metadata[ChoiceReply.quoteKey] == "Editor: \(question)")
        let expected = "In reply to “Editor: \(question)”\nNo"
        #expect(backend.sent.all.map(\.text) == [expected])
        let assistant = try #require(chat.messages.last)
        #expect(restored.chatHistory(chat, upTo: reply, excluding: assistant, inlineFiles: false).last?.content == expected)
        #expect(restored.choiceStatus(original, target: target, key: key, binary: true).picked == "No")
        #expect(try !click(restored, source: original))
        #expect(original.metadata[key] == "No")
    }

    @Test func historicalGroupPickRetainsQuestionAndRecipientThroughQueueRecovery() async throws {
        let url = temporaryStore()
        let backend = GroupBackend(name: "Editor")
        func reopen() -> AppStore {
            AppStore(storeURL: url, autoStart: false, backendFactory: { _ in backend },
                     keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        }
        let store = reopen()
        let author = Bot(name: "Editor"), other = Bot(name: "Reviewer")
        let source = ChatMessage(role: .assistant, content: "Should I ask @Reviewer for notes?", authorID: author.id)
        let newer = ChatMessage(role: .assistant, content: "Should I use the short title?", authorID: other.id)
        let group = GroupChat(name: "Books", memberIDs: [author.id, other.id], messages: [source, newer])
        store.bots = [author, other]
        store.groups = [group]
        store.setTotalTurnLimit(1)
        let busy = store.beginTurn(in: other, bot: other, assistant: nil)
        let target = ConversationActionTarget.group(groupID: group.id, botID: author.id)
        #expect(store.answerInferredChoice(target: target, source: source, shownContent: source.content, answer: .option("Yes")))
        #expect(!store.answerInferredChoice(target: target, source: source, shownContent: source.content, answer: .option("No")))
        #expect(store.turns.nextMessages.count == 1 && backend.sent.all.isEmpty)
        // A second queued answer is already below the first when the app reopens.
        #expect(store.answerInferredChoice(target: .group(groupID: group.id, botID: other.id),
                                          source: newer, shownContent: newer.content, answer: .option("No")))
        let restored = reopen()
        let team = try #require(restored.groups.first)
        let reply = try #require(team.messages.first { $0.role == .user })
        #expect(reply.replyToID == source.id && reply.content == "Yes")
        #expect(reply.metadata[TurnWaitCopy.recipients] == author.id.uuidString)
        #expect(restored.turns.nextMessages.count == 2)
        restored.resumeRestoredNextMessages()
        try await waitUntil { !restored.anyTurnRunning }
        restored.sendQueuedNextMessage()
        let send = try #require(backend.sent.all.first)
        let second = try #require(backend.sent.all.last)
        #expect(backend.sent.all.count == 2 && send.session.contains(author.id.uuidString.lowercased()))
        #expect(send.text.hasSuffix("Konrad: In reply to “Editor: \(source.content)”\nYes"))
        #expect(second.session.contains(other.id.uuidString.lowercased()))
        #expect(second.text.hasSuffix("Konrad: In reply to “Reviewer: \(newer.content)”\nNo"))
        let herdrContext = try GroupRouting.herdrContext(for: .init(id: author.id, name: author.name),
            groupName: team.name, members: restored.routingMembers(of: team), messages: team.messages,
            current: reply, limit: 500, userName: "Konrad")
        #expect(herdrContext.hasSuffix("Konrad: In reply to “Editor: \(source.content)”\nYes"))
        store.endTurn(busy.token)
    }

    @Test func twoBinaryCardsInOneMessageKeepIndependentAnswers() async throws {
        let backend = GroupBackend(name: "Editor")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend },
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let content = "```choices\nInclude photos?\n- Yes\n- No\n```\n```choices\nInclude maps?\n- Yes\n- No\n```"
        let source = ChatMessage(role: .assistant, content: content, metadata: ["picked.0": "Yes"])
        // Older picks carried the source row ID but no key on the reply itself.
        let previous = ChatMessage(role: .user, content: "Yes", replyToID: source.id)
        let bot = Bot(name: "Editor", messages: [source, previous])
        store.bots = [bot]
        let target = ConversationActionTarget.bot(botID: bot.id)
        let blocks = ChatCardParser.parseVisibleReply(content)
        #expect(!store.performCardAction(target: target, sourceID: source.id, index: 0, expected: blocks[0], choice: .option("No")))
        #expect(store.performCardAction(target: target, sourceID: source.id, index: 1, expected: blocks[1], choice: .option("No")))
        try await waitUntil { !store.anyTurnRunning }
        #expect(backend.sent.all.map(\.text) == ["In reply to “Editor: Include maps?”\nNo"])
        #expect(source.metadata["picked.0"] == "Yes" && source.metadata["picked.1"] == "No")
    }

    @Test func linkedTypedReplyAndStaleClicksCannotAnswerAgain() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let old = "Should I add the chart?"
        let inferred = ChatMessage(role: .assistant, content: old)
        let explicit = ChatMessage(role: .assistant, content: "```choices\nAdd a map?\n- Yes\n- No\n```")
        let typed = ChatMessage(role: .user, content: "No", replyToID: explicit.id)
        let bot = Bot(name: "Editor", messages: [explicit, inferred, typed])
        store.bots = [bot]
        let target = ConversationActionTarget.bot(botID: bot.id)
        let block = try #require(ChatCardParser.parseVisibleReply(explicit.content).first)
        #expect(store.choiceStatus(explicit, target: target, key: "picked.0", binary: true).picked == "No")
        #expect(!store.performCardAction(target: target, sourceID: explicit.id, index: 0, expected: block, choice: .option("Yes")))
        inferred.content = "Should I remove the chart?"
        #expect(!store.answerInferredChoice(target: target, source: inferred, shownContent: old, answer: .option("Yes")))
        let detached = ChatMessage(id: inferred.id, role: .assistant, content: old)
        #expect(!store.answerInferredChoice(target: target, source: detached, shownContent: old, answer: .option("Yes")))
        bot.archivedMembers = ["Retired"]
        #expect(!store.answerInferredChoice(target: target, source: inferred, shownContent: inferred.content, answer: .option("Yes")))
        #expect(bot.messages.count == 3)
    }
}
