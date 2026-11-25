import Foundation
import Testing
@testable import AgentApp

@MainActor struct ConversationActionsTests {
    @Test(arguments: [true, false]) func queuedChoiceKeepsCardAndRecipient(serverCap: Bool) async throws {
        let backend = GroupBackend(name: "Author")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend },
                             keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        store.setTotalTurnLimit(serverCap ? 4 : 1)
        store.setPerConnectionTurnLimit(1)
        let blocker = Bot(name: "Busy"), author = Bot(name: "Author"), other = Bot(name: "Other")
        store.bots = [blocker, author, other]
        let turn = store.beginTurn(in: blocker, bot: blocker, assistant: nil)
        let card = ChatMessage(role: .assistant, content: serverCap ? "Should I start?" : "```choices\nPick\n- One\n- Two\n```", authorID: author.id)
        let group = GroupChat(name: "Team", memberIDs: [author.id, other.id], messages: [card])
        store.groups = [group]
        let target = ConversationActionTarget.group(groupID: group.id, botID: author.id)
        func click() throws -> Bool {
            if serverCap {
                return store.answerInferredChoice(target: target, source: card, shownContent: card.content, answer: .option("Yes"))
            }
            return store.performCardAction(target: target, sourceID: card.id, index: 0,
                expected: try #require(ChatCardParser.parse(card.content).first), choice: .option("One"))
        }
        #expect(try click())
        #expect(try !click())
        #expect(store.errorMessage == nil && store.turns.nextMessages.count == 1)
        #expect(group.messages.last?.content == (serverCap ? "Waiting: 1 reply is already running on this server." : "Waiting: 1 reply is already running."))
        store.endTurn(turn.token)
        store.sendQueuedNextMessage()
        try await waitUntil { !store.anyTurnRunning }
        #expect(group.messages.filter { $0.role == .user }.map(\.replyToID) == [card.id])
        #expect(backend.sent.all.count == 1 && backend.sent.all[0].session.contains(author.id.uuidString.lowercased()))
    }

    @Test func multiSelectQueuesOneAnswerInCardOrderWithCustomText() async throws {
        let backend = GroupBackend(name: "Writer")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let card = ChatMessage(role: .assistant, content: "```choices-multiple\nInclude which?\n- One\n- Two\n- Three\n```")
        let bot = Bot(name: "Writer", messages: [card]), busy = Bot(name: "Busy")
        store.bots = [bot, busy]
        store.setTotalTurnLimit(1)
        let turn = store.beginTurn(in: busy, bot: busy, assistant: nil)
        let block = try #require(ChatCardParser.parse(card.content).first)
        #expect(block == .multiChoices(prompt: "Include which?", options: ["One", "Two", "Three"]))
        func submit(_ selection: ChatChoiceAnswer) -> Bool {
            store.performCardAction(target: .bot(botID: bot.id), sourceID: card.id, index: 0, expected: block, choice: selection)
        }
        #expect(!submit(.multiple(["missing"], other: "")) && card.metadata["picked.0"] == nil)
        #expect(!submit(.option("One")))
        #expect(submit(.multiple(["Three", "One"], other: "  Four ")))
        #expect(!submit(.multiple(["Two"], other: "")))
        #expect(store.turns.nextMessages.count == 1 && card.metadata["picked.0"] == "One\nThree\nFour")
        store.endTurn(turn.token)
        store.sendQueuedNextMessage()
        try await waitUntil { !store.anyTurnRunning }
        #expect(bot.messages.filter { $0.role == .user }.map(\.content) == ["One\nThree\nFour"])
        #expect(backend.sent.all.count == 1)
    }

    @Test func inferredChoiceSendsTheMarkerAndExpiresImmediately() async throws {
        let backend = GroupBackend(name: "Infra")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let card = ChatMessage(role: .assistant, content: "Which way?\n1. Build\n2. Ask Infra", isStreaming: true, turnState: .incomplete)
        let bot = Bot(name: "Planner", messages: [card]); store.bots = [bot]
        let target = ConversationActionTarget.bot(botID: bot.id)
        let shownContent = card.content

        #expect(!store.answerInferredChoice(target: target, source: card, shownContent: shownContent, answer: .option("2")))
        card.isStreaming = false
        #expect(!store.choiceStatus(card, target: target, key: ChatChoiceInference.answerKey, binary: false).enabled, "an interrupted turn is not a final answer")
        card.turnState = .finished
        #expect(store.choiceStatus(card, target: target, key: ChatChoiceInference.answerKey, binary: false).enabled)
        #expect(!store.answerInferredChoice(target: target, source: card, shownContent: shownContent, answer: .option("Ask Infra")))
        #expect(!store.answerInferredChoice(target: target, source: card, shownContent: shownContent, answer: .other(" \n")))
        #expect(store.answerInferredChoice(target: target, source: card, shownContent: shownContent, answer: .option("2")))
        #expect(!store.choiceStatus(card, target: target, key: ChatChoiceInference.answerKey, binary: false).enabled)
        #expect(!store.answerInferredChoice(target: target, source: card, shownContent: shownContent, answer: .option("1")))
        try await waitUntil { !store.anyTurnRunning }
        #expect(bot.messages.filter { $0.role == .user }.map(\.content) == ["2"])
        #expect(bot.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(card.metadata[ChatChoiceInference.answerKey] == "2")
    }

    @Test func nonBinaryChoicesExpireAndOtherRepliesToTheAskingGroupMember() async throws {
        let backend = GroupBackend(name: "B")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B"); store.bots = [a, b]
        let explicit = ChatMessage(role: .assistant, content: "```choices\nChoose\n- One\n- Two\n```", authorID: a.id)
        let inferred = ChatMessage(role: .assistant, content: "Should I start?", authorID: a.id)
        let latest = ChatMessage(role: .assistant, content: "Would you like me to wait?", authorID: b.id)
        let group = GroupChat(name: "Team", memberIDs: [a.id, b.id], messages: [explicit, inferred, latest]); store.groups = [group]
        let aTarget = ConversationActionTarget.group(groupID: group.id, botID: a.id)
        let bTarget = ConversationActionTarget.group(groupID: group.id, botID: b.id)
        let card = try #require(ChatCardParser.parse(explicit.content).first)

        #expect(store.performCardAction(target: aTarget, sourceID: explicit.id, index: 0, expected: card, choice: .option("One")))
        try await waitUntil { !store.anyTurnRunning }
        #expect(!store.answerInferredChoice(target: bTarget, source: inferred, shownContent: inferred.content, answer: .option("Yes")))
        #expect(!store.answerInferredChoice(target: aTarget, source: latest, shownContent: latest.content, answer: .option("Yes")))
        #expect(store.answerInferredChoice(target: bTarget, source: latest, shownContent: latest.content, answer: .other(" Wait until Monday. ")))
        try await waitUntil { !store.anyTurnRunning }
        #expect(backend.sent.all.count == 2 && backend.sent.all.last?.session.contains(b.id.uuidString.lowercased()) == true)
        #expect(group.messages.filter { $0.role == .user }.map(\.content) == ["One", "Wait until Monday."])
        #expect(group.messages.last { $0.role == .user }?.replyToID == latest.id)
    }

    @Test func groupChoiceTargetsAuthorDespiteSelectedPrivateBot() async throws {
        let backend = GroupBackend(name: "B")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B"), c = Bot(name: "C")
        store.bots = [a, b, c]
        let card = ChatMessage(role: .assistant, content: "```choices\nChoose\n- One\n- Two\n```", authorID: b.id)
        let group = GroupChat(name: "Team", memberIDs: [b.id, c.id], messages: [card]); store.groups = [group]
        store.selectedGroup = nil; store.selectedBot = a
        let blocks = ChatCardParser.parse(card.content)
        let index = try #require(blocks.firstIndex { if case .choices = $0 { true } else { false } })
        #expect(store.performCardAction(target: .group(groupID: group.id, botID: b.id), sourceID: card.id, index: index, expected: blocks[index], choice: .option("One")))
        try await waitUntil { !store.anyTurnRunning }
        #expect(a.messages.isEmpty && b.messages.isEmpty && c.messages.isEmpty)
        #expect(backend.sent.all.count == 1)
        #expect(backend.sent.all.first?.session.contains(b.id.uuidString.lowercased()) == true)
        #expect(group.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(card.metadata["picked.\(index)"] == "One")
        #expect(!store.performCardAction(target: .group(groupID: group.id, botID: b.id), sourceID: card.id, index: index, expected: blocks[index], choice: .option("One")),
                "a card is answered once")
    }

    @Test func staleDraftAndRemovedAuthorCannotSend() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Author"); store.bots = [bot]
        let card = ChatMessage(role: .assistant, content: "```draft\nTo: a@example.com\nSubject: Original\n\nHello\n```", authorID: bot.id)
        let group = GroupChat(name: "Team", memberIDs: [bot.id], messages: [card]); store.groups = [group]
        let blocks = ChatCardParser.parse(card.content)
        let index = try #require(blocks.firstIndex { if case .draft = $0 { true } else { false } })
        card.content = card.content.replacingOccurrences(of: "Original", with: "Changed")
        #expect(!store.performCardAction(target: .group(groupID: group.id, botID: bot.id), sourceID: card.id, index: index, expected: blocks[index]))
        #expect(store.errorMessage?.contains("card changed") == true)
        group.memberIDs = []
        #expect(store.actionConversation(.group(groupID: group.id, botID: bot.id)) == nil)
        #expect(group.messages.count == 1)
    }

    @Test func anUnclosedDraftCanBeSentWithTrailingNewlinesAndAHiddenBlock() async throws {
        let backend = GroupBackend(name: "Author")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let intro = "Here’s the draft.\n\n"
        let draft = "```swarmhub\n{}\n```\n\n```draft\nTo: maya@example.com\n\nHello.\n\n"
        let card = ChatMessage(role: .assistant, content: intro + draft, turnState: .finished)
        let bot = Bot(name: "Author", messages: [card]); store.bots = [bot]
        let shown = try #require(ChatCardParser.parseVisibleReply(draft).first)
        #expect(shown == .draft(DraftCard(to: "maya@example.com", body: "Hello.\n\n")))
        let indexes = ReplyLayout.blockIndexes([.text(intro), .text(draft)], content: card.content)
        #expect(indexes == [[-1], [1]])

        #expect(store.performCardAction(target: .bot(botID: bot.id), sourceID: card.id, index: 1, expected: shown))
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.messages.filter { $0.role == .user }.map(\.content) == ["Send it"])
        #expect(card.metadata["draftSent.1"] == "1" && store.errorMessage == nil)
    }

    @Test func aCardWrittenByAnotherMemberIsRefused() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B"); store.bots = [a, b]
        let card = ChatMessage(role: .assistant, content: "```choices\nChoose\n- One\n```", authorID: a.id)
        let group = GroupChat(name: "Team", memberIDs: [a.id, b.id], messages: [card]); store.groups = [group]
        let blocks = ChatCardParser.parse(card.content)
        #expect(!store.performCardAction(target: .group(groupID: group.id, botID: b.id), sourceID: card.id, index: 0, expected: blocks[0], choice: .option("One")))
        #expect(group.messages.count == 1)
    }

    @Test func duplicateNamesAreMentionedByIDAndABareNameIsRefused() async throws {
        let first = Bot(name: "Ann"), second = Bot(name: "ann"), solo = Bot(name: "Ben")
        let members = [first, second, solo].map { GroupRouting.Member(id: $0.id, name: $0.name) }
        let firstName = GroupRouting.mentionName(members[0], members: members)
        #expect(firstName == "Ann#" + first.id.uuidString.prefix(8).lowercased())
        #expect(GroupRouting.mentionName(members[2], members: members) == "Ben")
        #expect(GroupRouting.recipients(of: "@\(firstName) do this", members: members) == [first.id])
        #expect(GroupRouting.ambiguousMentions(in: "@\(firstName) do this", members: members).isEmpty)
        #expect(GroupRouting.ambiguousMentions(in: "@Ann do this", members: members) == ["@Ann"])
        #expect(GroupRouting.ambiguousMentions(in: "@Ben and @Bob", members: members).isEmpty, "unknown names stay ignored")

        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        store.bots = [first, second, solo]
        let group = GroupChat(name: "Team", memberIDs: [first.id, second.id, solo.id]); store.groups = [group]
        #expect(!store.send(text: "@Ann please", to: group))
        #expect(group.messages.isEmpty && store.errorMessage?.contains("@Ann") == true)
    }
}
