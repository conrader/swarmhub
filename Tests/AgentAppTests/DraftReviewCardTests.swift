import Foundation
import Testing
@testable import AgentApp

@MainActor struct DraftReviewCardTests {
    @Test func recognizesDraftEmailAndMessageFences() {
        #expect(ChatCardParser.parse("```draft\nChannel: Slack\nto: #launch\n\nFirst line\n\nSubject: Part of the body\n\n```") == [
            .draft(.init(to: "#launch", body: "First line\n\nSubject: Part of the body\n", channel: "Slack")),
        ])
        #expect(ChatCardParser.parse("```email\nTo: maya@example.com\nSubject: Launch update\n\nHi Maya!\n```") == [
            .draft(.init(to: "maya@example.com", subject: "Launch update", body: "Hi Maya!", channel: "Email")),
        ])
        #expect(ChatCardParser.parse("```message\nVia: WhatsApp\nto: Maya\n\nReady?\n```") == [
            .draft(.init(to: "Maya", body: "Ready?", channel: "WhatsApp")),
        ])
        #expect(ChatCardParser.parse("```EMAIL\nvia: Work email\n\nHi!\n```") == [
            .draft(.init(body: "Hi!", channel: "Work email")),
        ])
    }

    @Test func uneditedSendKeepsTheOriginalReplyAndMarker() async throws {
        let backend = GroupBackend(name: "Writer")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend },
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let card = ChatMessage(role: .assistant, content: "```draft\nTo: Maya\n\nHello!\n```")
        let bot = Bot(name: "Writer", messages: [card])
        store.bots = [bot]
        let expected = try #require(ChatCardParser.parse(card.content).first)

        #expect(store.performCardAction(target: .bot(botID: bot.id), sourceID: card.id, index: 0, expected: expected))
        try await waitUntil { !store.anyTurnRunning }
        #expect(backend.sent.all.map(\.text) == ["Send it"])
        #expect(bot.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(card.metadata["draftSent.0"] == "1")
    }

    @Test func editedSendPreservesTheExactFieldsAndCanOnlySendOnce() async throws {
        let backend = GroupBackend(name: "Writer")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend },
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let card = ChatMessage(role: .assistant, content: "```email\nTo: Maya\nSubject: Original\n\nHello!\n```")
        let bot = Bot(name: "Writer", messages: [card])
        store.bots = [bot]
        let target = ConversationActionTarget.bot(botID: bot.id)
        let expected = try #require(ChatCardParser.parse(card.content).first)
        let edited = DraftCard(to: "Ari <ari@example.com>", subject: "Revised: “Launch”",
                               body: "\n  Hi Ari,\n\n```\nSubject: still the body\n```\n\nThanks!  \n", channel: "Email")

        #expect(store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected, editedDraft: edited))
        try await waitUntil { !store.anyTurnRunning }
        let sent = try #require(backend.sent.all.first?.text)
        let prefix = "Send this edited draft:\n"
        #expect(sent.hasPrefix(prefix))
        let fields = try JSONDecoder().decode([String: String].self, from: Data(sent.dropFirst(prefix.count).utf8))
        #expect(fields == ["to": "Ari <ari@example.com>", "subject": "Revised: “Launch”", "body": edited.body, "channel": "Email"])
        #expect(bot.messages.first { $0.role == .user }?.content == sent)
        #expect(bot.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(card.metadata["draftSent.0"] == "edited")
        #expect(!store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected, editedDraft: edited))
        #expect(backend.sent.all.count == 1)
    }

    @Test func editedSendRejectsStreamingStaleAndOtherMembersDrafts() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let author = Bot(name: "Writer"), other = Bot(name: "Other")
        store.bots = [author, other]
        let card = ChatMessage(role: .assistant, content: "```message\nHi!\n```", isStreaming: true, authorID: author.id)
        let group = GroupChat(name: "Team", memberIDs: [author.id, other.id], messages: [card])
        store.groups = [group]
        let target = ConversationActionTarget.group(groupID: group.id, botID: author.id)
        let expected = try #require(ChatCardParser.parse(card.content).first)
        let edited = DraftCard(body: "Revised")

        #expect(!store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected, editedDraft: edited))
        card.isStreaming = false
        let turn = store.beginTurn(in: group, bot: other, assistant: nil)
        #expect(!store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected, editedDraft: edited))
        store.endTurn(turn.token)
        #expect(!store.performCardAction(target: .group(groupID: group.id, botID: other.id),
                                         sourceID: card.id, index: 0, expected: expected, editedDraft: edited))
        card.content = "```message\nChanged since review\n```"
        #expect(!store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected, editedDraft: edited))
        #expect(store.errorMessage?.contains("card changed") == true)
        #expect(group.messages.count == 1 && card.metadata["draftSent.0"] == nil)
    }

    @Test func botInstructionsTeachNewAndRunningAgentsTheDraftCard() throws {
        let client = HerdrClient(baseURL: try #require(URL(string: HerdrBackend.defaultURL)), token: "test")
        let backend = HerdrBackend(client: client, botName: "Writer", botID: UUID(), template: nil)
        let entry = try #require(backend.notes.first { $0.marker == HerdrBackend.draftMarker })
        #expect(backend.launchInstructions?.contains(entry.note) == true)
        #expect(entry.note.contains("approve before sending") && entry.note.contains("Edit, Copy, and Send"))
        let fence = try #require(entry.note.range(of: "```draft"))
        #expect(ChatCardParser.parse(String(entry.note[fence.lowerBound...])) == [
            .draft(.init(to: "maya@example.com", subject: "Launch update", body: "Hi Maya, we're ready to launch.", channel: "Email")),
        ])
        #expect(HerdrClient.notes(reminder: nil, once: backend.notes, tasks: [HerdrBackend.choiceNote]) == [entry.note])
        #expect(HerdrClient.notes(reminder: nil, once: backend.notes, tasks: [HerdrBackend.choiceNote, entry.note]).isEmpty)
    }
}
