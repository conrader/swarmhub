import Foundation
import Testing
@testable import AgentApp

@MainActor struct ConversationActionsTests {
    @Test func inferredChoiceSendsTheMarkerAndExpiresImmediately() async throws {
        let backend = GroupBackend(name: "Infra")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let card = ChatMessage(role: .assistant, content: "Which way?\n1. Build\n2. Ask Infra", isStreaming: true, turnState: .incomplete)
        let bot = Bot(name: "Planner", messages: [card]); store.bots = [bot]
        let target = ConversationActionTarget.bot(botID: bot.id)
        let options = try #require(ChatChoiceInference.options(in: card.content))

        #expect(!store.answerInferredChoice(target: target, source: card, expected: options, answer: .option("2")))
        card.isStreaming = false
        #expect(!store.canAnswerChoice(card, target: target), "an interrupted turn is not a final answer")
        card.turnState = .finished
        #expect(store.canAnswerChoice(card, target: target))
        #expect(!store.answerInferredChoice(target: target, source: card, expected: options, answer: .option("Ask Infra")))
        #expect(!store.answerInferredChoice(target: target, source: card, expected: options, answer: .other(" \n")))
        #expect(store.answerInferredChoice(target: target, source: card, expected: options, answer: .option("2")))
        #expect(!store.canAnswerChoice(card, target: target))
        #expect(!store.answerInferredChoice(target: target, source: card, expected: options, answer: .option("1")))
        try await waitUntil { !store.anyTurnRunning }
        #expect(bot.messages.filter { $0.role == .user }.map(\.content) == ["2"])
        #expect(bot.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(card.metadata[ChatChoiceInference.answerKey] == "2")
    }

    @Test func choiceActionsRejectOlderMessagesAndOtherRepliesToTheAskingGroupMember() async throws {
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
        let earlierOptions = try #require(ChatChoiceInference.options(in: inferred.content))
        let latestOptions = try #require(ChatChoiceInference.options(in: latest.content))

        #expect(!store.performCardAction(target: aTarget, sourceID: explicit.id, index: 0, expected: card, choice: .option("One")))
        #expect(!store.answerInferredChoice(target: aTarget, source: inferred, expected: earlierOptions, answer: .option("Yes")))
        #expect(!store.answerInferredChoice(target: aTarget, source: latest, expected: latestOptions, answer: .option("Yes")))
        #expect(store.answerInferredChoice(target: bTarget, source: latest, expected: latestOptions, answer: .other(" Wait until Monday. ")))
        try await waitUntil { !store.anyTurnRunning }
        #expect(backend.sent.all.count == 1 && backend.sent.all.first?.session.contains(b.id.uuidString.lowercased()) == true)
        #expect(group.messages.filter { $0.role == .user }.map(\.content) == ["Wait until Monday."])
        #expect(group.messages.first { $0.role == .user }?.replyToID == latest.id)
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
