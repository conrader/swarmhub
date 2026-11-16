import Foundation
import Testing
@testable import AgentApp

// MARK: Data URLs and limits

@Test func textFilesAreFencedWithTheirName() {
    #expect(AttachmentEncoder.fencedBlock(name: "a.txt", text: "hi\n") == "File: a.txt\n```\nhi\n```")
    #expect(AttachmentEncoder.fencedBlock(name: "r.md", text: "```swift\nx\n```") == "File: r.md\n````\n```swift\nx\n```\n````")
    let file = ChatAttachment(id: UUID(), kind: .text, name: "a.txt", mimeType: "text/plain", byteCount: 2, text: "hi")
    #expect(AttachmentEncoder.compose(text: "Look", attachments: [file]) == "Look\n\nFile: a.txt\n```\nhi\n```")
    #expect(AttachmentEncoder.compose(text: "Look", attachments: []) == "Look")
}

// MARK: Card parsing

@Test func choicesFenceBecomesAQuestionCard() {
    let blocks = ChatCardParser.parse("Pick a slot.\n\n```choices\nWhich day suits you?\n- Monday\n- Tuesday\n3. Friday\n```")
    #expect(blocks == [.markdown("Pick a slot."), .choices(prompt: "Which day suits you?", options: ["Monday", "Tuesday", "Friday"])])
}

@Test func markedTrailingNumberedListBecomesChoices() {
    let text = "How should I proceed?\n<!-- choices -->\n1. Ship today\n2) Wait for QA"
    #expect(ChatCardParser.parse(text) == [.markdown("How should I proceed?"), .choices(prompt: "", options: ["Ship today", "Wait for QA"])])
}

@Test func ordinaryListsAndSingleOptionChoicesStayMarkdown() {
    let unmarked = "Steps:\n1. Build\n2. Test"
    #expect(ChatCardParser.parse(unmarked) == [.markdown(unmarked)])
    let notTrailing = "<!-- choices -->\n1. A\n2. B\n\nThen more prose."
    #expect(ChatCardParser.parse(notTrailing) == [.markdown(notTrailing)])
    #expect(ChatCardParser.parse("```choices\n- Only one\n```") == [.code(language: "choices", body: "- Only one")])
    #expect(ChatCardParser.parse("```swift\nlet x = 1\n```") == [.code(language: "swift", body: "let x = 1")])
}

@Test func draftFenceParsesHeadersAndBody() {
    let blocks = ChatCardParser.parse("```draft\nto: Maya <maya@example.com>\nSubject: Launch update\n\nHi Maya,\n\nAll set.\n```")
    #expect(blocks == [.draft(DraftCard(to: "Maya <maya@example.com>", subject: "Launch update", body: "Hi Maya,\n\nAll set."))])
    #expect(ChatCardParser.parse("```draft\nJust a body: with a colon\n```") == [.draft(DraftCard(to: nil, subject: nil, body: "Just a body: with a colon"))])
}

@Test func markdownImagesAndBareLinksAreFound() {
    let text = "See ![chart](https://example.com/c.png) and https://example.com/report, plus [docs](https://docs.example.com).\n`https://in.code/x` ![local](file:///etc/x.png)"
    let blocks = ChatCardParser.parse(text)
    #expect(blocks.contains(.image(alt: "chart", url: "https://example.com/c.png")))
    #expect(!blocks.contains { if case .image(_, let url) = $0 { url.hasPrefix("file:") } else { false } })
    #expect(ChatCardParser.bareURLs(in: text) == ["https://example.com/report"])
    #expect(ChatCardParser.links(in: text) == ["https://docs.example.com", "https://example.com/report"])
    #expect(ChatCardParser.bareURLs(in: "(see https://a.example/x).") == ["https://a.example/x"])
    #expect(ChatCardParser.pillLabel("https://www.example.com/a/b?q=1") == "example.com/a/b")
}

// MARK: Tapbacks and unread

@Test @MainActor func tapbacksAndManualUnreadPersist() throws {
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let message = ChatMessage(role: .assistant, content: "Done")
    let first = Bot(name: "One", messages: [message]), second = Bot(name: "Two")
    store.bots = [first, second]; store.selectedBot = first
    store.toggleReaction("👍", on: message); store.toggleReaction("❤️", on: message); store.toggleReaction("👍", on: message)
    store.markUnread(second)

    let restored = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let restoredSecond = try #require(restored.bots.first { $0.name == "Two" })
    #expect(restored.bots.first { $0.name == "One" }?.messages.first?.reactions == ["❤️"])
    #expect(restoredSecond.manualUnread && restoredSecond.isUnread)
    restored.open(restoredSecond)
    #expect(!restoredSecond.isUnread)
    #expect(AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults()).bots.first { $0.name == "Two" }?.manualUnread == false)
}

// MARK: Media

