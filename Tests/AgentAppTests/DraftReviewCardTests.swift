import Foundation
import Testing
@testable import AgentApp

@MainActor struct DraftReviewCardTests {
    @Test func pageDraftRequiresACompleteNamedDocument() {
        let body = #"{"title":"Release notes","markdown":"- One\n- Two"}"#
        let source = "```page-draft\n" + body + "\n```"
        #expect(ChatCardParser.parse(source) == [.pageDraft(.init(title: "Release notes", markdown: "- One\n- Two"))])
        #expect(ChatCardParser.parse(source, interpretCards: false) == [.code(language: "page-draft", body: body)])
        #expect(ChatCardParser.parse("```page-draft\n" + body) == [.code(language: "page-draft", body: body)])
        for invalid in ["{}", #"{"title":" ","markdown":"A"}"#, #"{"title":"Title","markdown":" "}"#] {
            #expect(ChatCardParser.parse("```page-draft\n" + invalid + "\n```") == [.code(language: "page-draft", body: invalid)])
        }
        let projected = TranscriptText(reply: source, segments: nil).string
        #expect(projected.contains("Release notes") && projected.contains("One") && projected.contains("Two"))
    }

    @Test(arguments: [PageDraft.Decision.approve, .shorten])
    func pageReviewDeliversTheSelectedWholeRevisionOnlyOnce(decision: PageDraft.Decision) async throws {
        let writer = Bot(name: "Patch"), peer = Bot(name: "Scout")
        let backend = GroupBackend(name: writer.name), otherBackend = GroupBackend(name: peer.name)
        let id = writer.id
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { $0.id == id ? backend : otherBackend },
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let draft = PageDraft(title: "v3", markdown: String(repeating: "Review this wording. ", count: 100) + "β")
        let json = try JSONEncoder().encode(draft)
        let card = ChatMessage(role: .assistant, content: "```page-draft\n" + String(decoding: json, as: UTF8.self) + "\n```", authorID: writer.id)
        let group = GroupChat(name: "Release", memberIDs: [writer.id, peer.id], messages: [card])
        store.bots = [writer, peer]; store.groups = [group]
        let target = ConversationActionTarget.group(groupID: group.id, botID: writer.id)
        func review(_ draft: PageDraft, in target: ConversationActionTarget) -> Bool {
            store.performCardAction(target: target, sourceID: card.id, index: 0, expected: .pageDraft(draft), pageDecision: decision)
        }
        #expect(!review(draft, in: .group(groupID: group.id, botID: peer.id)))
        #expect(!review(.init(title: draft.title, markdown: "Different version"), in: target))
        card.isStreaming = true
        #expect(!review(draft, in: target))
        card.isStreaming = false
        #expect(review(draft, in: target))
        try await waitUntil(timeout: .seconds(5)) { !store.anyTurnRunning }
        #expect(!review(draft, in: target))
        let reply = try #require(group.messages.first { $0.role == .user })
        #expect(reply.replyToID == card.id && reply.content == decision.reply)
        let quote = try #require(reply.metadata[ChoiceReply.quoteKey])
        #expect(try JSONDecoder().decode(PageDraft.self, from: Data(quote.utf8)) == draft)
        #expect(backend.sent.all.count == 1 && otherBackend.sent.all.isEmpty)
        #expect(backend.sent.all.first?.text.hasSuffix(reply.modelText) == true)
        #expect(card.metadata["pageReview.0"] == decision.rawValue)
    }

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
        try await waitUntil(timeout: .seconds(5)) { !store.anyTurnRunning }
        #expect(!store.performCardAction(target: .bot(botID: bot.id), sourceID: card.id, index: 0, expected: expected))
        #expect(backend.sent.all.map(\.text) == ["Send it"])
        #expect(bot.messages.first { $0.role == .user }?.replyToID == card.id)
        #expect(card.metadata["draftSent.0"] == "1")
    }

    @Test(arguments: [false, true])
    func editedSendPreservesTheExactFieldsAndCanOnlySendOnce(withWaitingGoal: Bool) async throws {
        let backend = GroupBackend(name: "Writer")
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend },
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let card = ChatMessage(role: .assistant, content: "```email\nTo: Maya\nSubject: Original\n\nHello!\n```")
        let bot = Bot(name: "Writer", messages: [card])
        store.bots = [bot]
        var goal = ChatGoal(objective: "Work on the outline", destination: store.goalDestination(for: bot))
        goal.wait("Review the draft")
        if withWaitingGoal { bot.goal = goal }
        let previousGoal = bot.goal
        let target = ConversationActionTarget.bot(botID: bot.id)
        let expected = try #require(ChatCardParser.parse(card.content).first)
        let edited = DraftCard(to: "Ari <ari@example.com>", subject: "Revised: “Launch”",
                               body: "\n  Hi Ari,\n\n```\nSubject: still the body\n```\n\nThanks!  \n", channel: "Email")

        #expect(store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected, editedDraft: edited))
        try await waitUntil(timeout: .seconds(5)) { !store.anyTurnRunning }
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
        #expect(bot.goal == previousGoal)
    }

    @Test(arguments: [true, false])
    func groupApprovalNamesOnlyTheSelectedDraftAndAuthor(sameMessage: Bool) async throws {
        let writer = Bot(name: "Writer"), other = Bot(name: "Reviewer")
        let backend = GroupBackend(name: writer.name), otherBackend = GroupBackend(name: other.name)
        let writerID = writer.id
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { $0.id == writerID ? backend : otherBackend },
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let first = "```email\nTo: Maya\nSubject: Review\n\nAsk @Reviewer.\n```"
        let second = "```email\nTo: Ari\n\nDifferent draft\n```"
        let card = ChatMessage(role: .assistant, content: sameMessage ? first + "\n\n" + second : first, authorID: writer.id)
        let messages = sameMessage ? [card] : [card, ChatMessage(role: .assistant, content: second, authorID: writer.id)]
        let group = GroupChat(name: "Team", memberIDs: [writer.id, other.id], messages: messages)
        store.bots = [writer, other]
        store.groups = [group]
        let target = ConversationActionTarget.group(groupID: group.id, botID: writer.id)
        let expected = try #require(ChatCardParser.parse(card.content).first)
        #expect(store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected))
        try await waitUntil(timeout: .seconds(5)) { !store.anyTurnRunning }
        #expect(!store.performCardAction(target: target, sourceID: card.id, index: 0, expected: expected))
        let row = try #require(group.messages.first { $0.role == .user })
        #expect(row.replyToID == card.id && row.content == "Send it")
        let quote = try #require(row.metadata[ChoiceReply.quoteKey])
        let fields = try JSONDecoder().decode([String: String].self, from: Data(quote.utf8))
        #expect(fields == ["channel": "Email", "to": "Maya", "subject": "Review", "body": "Ask @Reviewer."])
        #expect(backend.sent.all.count == 1 && otherBackend.sent.all.isEmpty)
        #expect(backend.sent.all.first?.text.hasSuffix("In reply to “\(quote)”\nSend it") == true)
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
