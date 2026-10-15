import Foundation
import Testing
@testable import AgentApp

@MainActor struct ConversationActionsTests {
    @Test func groupChoiceTargetsAuthorDespiteSelectedPrivateBot() async throws {
        let backend = GroupBackend(name: "B")
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B"), c = Bot(name: "C")
        store.bots = [a, b, c]
        let card = ChatMessage(role: .assistant, content: "```choices\nChoose\n- One\n- Two\n```", authorID: b.id)
        let group = GroupChat(name: "Team", memberIDs: [b.id, c.id], messages: [card]); store.groups = [group]
        store.selectedGroup = nil; store.selectedBot = a
        let blocks = ChatCardParser.parse(card.content)
        let index = try #require(blocks.firstIndex { if case .choices = $0 { true } else { false } })
        #expect(store.performCardAction(target: .group(groupID: group.id, botID: b.id), sourceID: card.id, index: index, expected: blocks[index], choice: "One"))
        try await waitUntil { store.isIdle }
        #expect(a.messages.isEmpty && b.messages.isEmpty && c.messages.isEmpty)
        #expect(backend.sent.all.count == 1)
        #expect(backend.sent.all.first?.session.contains(b.id.uuidString.lowercased()) == true)
        #expect(group.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(card.metadata["picked.\(index)"] == "One")
        #expect(!store.performCardAction(target: .group(groupID: group.id, botID: b.id), sourceID: card.id, index: index, expected: blocks[index], choice: "One"),
                "a card is answered once")
    }

    @Test func choiceInAThreadStaysInThatThreadAfterTheSelectionMoves() async throws {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let owner = Bot(name: "Owner"), other = Bot(name: "Other")
        let card = ChatMessage(role: .assistant, content: "```choices\nPick\n- Left\n- Right\n```")
        let thread = ChatThread(parentMessageID: UUID(), parentSessionID: nil, hermesSessionID: nil, messages: [card])
        owner.threads = [thread]; store.bots = [owner, other]; store.selectedBot = other
        let blocks = ChatCardParser.parse(card.content)
        let index = try #require(blocks.firstIndex { if case .choices = $0 { true } else { false } })
        #expect(!store.performCardAction(target: .bot(botID: owner.id, threadID: thread.id), sourceID: card.id, index: index, expected: blocks[index], choice: "Middle"),
                "only an offered option is sent")
        #expect(store.performCardAction(target: .bot(botID: owner.id, threadID: thread.id), sourceID: card.id, index: index, expected: blocks[index], choice: "Right"))
        try await waitUntil { store.isIdle }
        #expect(thread.messages.first { $0.role == .user }?.content == "Right")
        #expect(thread.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(owner.messages.isEmpty && other.messages.isEmpty)
    }

    @Test func staleDraftAndRemovedAuthorCannotSend() throws {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
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
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B"); store.bots = [a, b]
        let card = ChatMessage(role: .assistant, content: "```choices\nChoose\n- One\n```", authorID: a.id)
        let group = GroupChat(name: "Team", memberIDs: [a.id, b.id], messages: [card]); store.groups = [group]
        let blocks = ChatCardParser.parse(card.content)
        #expect(!store.performCardAction(target: .group(groupID: group.id, botID: b.id), sourceID: card.id, index: 0, expected: blocks[0], choice: "One"))
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

        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        store.bots = [first, second, solo]
        let group = GroupChat(name: "Team", memberIDs: [first.id, second.id, solo.id]); store.groups = [group]
        #expect(!store.send(text: "@Ann please", to: group))
        #expect(group.messages.isEmpty && store.errorMessage?.contains("@Ann") == true)
    }
}
