import Foundation
import Testing
@testable import AgentApp

// MARK: Data URLs and limits

@Test func largeImagesAreDownscaledToTheLongEdgeLimit() throws {
    let opaque = try AttachmentEncoder.encodeImage(syntheticImage(width: 3000, height: 1500, alpha: false))
    #expect(opaque.mime == "image/jpeg")
    let (width, height) = pixelSize(opaque.data)
    #expect(width == 2048 && height == 1024)

    let transparent = try AttachmentEncoder.encodeImage(syntheticImage(width: 1000, height: 2500, alpha: true))
    #expect(transparent.mime == "image/png" && max(pixelSize(transparent.data).0, pixelSize(transparent.data).1) == 2048)
}

@Test func smallSupportedImagesPassThroughUnchanged() throws {
    let png = syntheticImage(width: 64, height: 48, alpha: true)
    let result = try AttachmentEncoder.encodeImage(png)
    #expect(result.data == png && result.mime == "image/png")
    let url = AttachmentEncoder.dataURL(mime: result.mime, data: result.data)
    #expect(url.hasPrefix("data:image/png;base64,") && Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))) == png)
    #expect(AttachmentEncoder.dataURLLength(mime: "image/png", byteCount: png.count) == url.utf8.count)
}

@Test func imagesThatCannotFitTheEncodedLimitAreRefused() throws {
    let noisy = syntheticImage(width: 800, height: 800, alpha: false, noise: true)
    #expect(throws: AttachmentError.tooLarge("noise.png", "5 MB after encoding")) { try AttachmentEncoder.encodeImage(noisy, name: "noise.png", maxBytes: 2_000) }
    // A large noisy image is re-encoded until its data URL fits the real 5 MB limit.
    let big = try AttachmentEncoder.encodeImage(syntheticImage(width: 2600, height: 2600, alpha: false, noise: true))
    #expect(AttachmentEncoder.dataURLLength(mime: big.mime, byteCount: big.data.count) <= AttachmentEncoder.maxImageDataURLBytes)
    #expect(max(pixelSize(big.data).0, pixelSize(big.data).1) <= 2048)
}

@Test func unsupportedImageFormatsAndBinaryFilesAreRefused() throws {
    let tiff = syntheticImage(width: 10, height: 10, alpha: false, type: .tiff)
    #expect(throws: AttachmentError.unsupported("scan.tiff")) { try AttachmentEncoder.encodeImage(tiff, name: "scan.tiff") }
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-attach-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = AttachmentEncoder(directory: directory.appending(path: "attachments"))
    let binary = directory.appending(path: "blob.bin"); try Data([0, 1, 2, 0, 255]).write(to: binary)
    #expect(throws: AttachmentError.unsupported("blob.bin")) { try encoder.prepare(fileURL: binary) }
    let big = directory.appending(path: "big.txt"); try Data(repeating: 65, count: AttachmentEncoder.maxTextBytes + 1).write(to: big)
    #expect(throws: AttachmentError.tooLarge("big.txt", "200 KB")) { try encoder.prepare(fileURL: big) }
    let note = directory.appending(path: "note.txt"); try Data("line one\n".utf8).write(to: note)
    let text = try encoder.prepare(fileURL: note)
    #expect(text.kind == .text && text.text == "line one\n" && text.fileName == nil)
    let picture = directory.appending(path: "pic.png"); try syntheticImage(width: 20, height: 20, alpha: false).write(to: picture)
    let image = try encoder.prepare(fileURL: picture)
    #expect(image.kind == .image && image.mimeType == "image/png")
    #expect(try encoder.dataURL(for: image).hasPrefix("data:image/png;base64,"))
}

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
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let message = ChatMessage(role: .assistant, content: "Done")
    let first = Bot(name: "One", messages: [message]), second = Bot(name: "Two")
    store.bots = [first, second]; store.selectedBot = first
    store.toggleReaction("👍", on: message); store.toggleReaction("❤️", on: message); store.toggleReaction("👍", on: message)
    store.markUnread(second)

    let restored = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let restoredSecond = try #require(restored.bots.first { $0.name == "Two" })
    #expect(restored.bots.first { $0.name == "One" }?.messages.first?.reactions == ["❤️"])
    #expect(restoredSecond.manualUnread && restoredSecond.isUnread)
    restored.open(restoredSecond)
    #expect(!restoredSecond.isUnread)
    #expect(AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults()).bots.first { $0.name == "Two" }?.manualUnread == false)
}

// MARK: Media

@Test func mediaListsAttachmentsImagesAndLinksNewestFirst() {
    let old = Date(timeIntervalSince1970: 1_000), mid = Date(timeIntervalSince1970: 2_000), new = Date(timeIntervalSince1970: 3_000)
    let photo = ChatAttachment(id: UUID(), kind: .image, name: "photo.png", mimeType: "image/png", byteCount: 10, fileName: "x.png")
    let sent = ChatMessage(role: .user, content: "look", createdAt: old, attachments: [photo])
    let reply = ChatMessage(role: .assistant, content: "Chart: ![q3](https://example.com/q3.png) and https://example.com/source", createdAt: mid)
    let note = ChatMessage(role: .system, content: "https://ignored.example", createdAt: new)
    let bot = Bot(name: "Media", messages: [sent, reply, note])
    let thread = ChatThread(parentMessageID: reply.id, parentSessionID: "s", hermesSessionID: "f", messages: [ChatMessage(role: .assistant, content: "Also [this](https://example.com/thread)", createdAt: new)])
    bot.threads = [thread]
    let items = MediaExtractor.items(in: bot)
    #expect(items.map(\.kind) == [.link, .link, .image, .image])
    #expect(items[0].url == "https://example.com/thread" && items[0].threadID == thread.id)
    #expect(items[1].url == "https://example.com/source" && items[1].messageID == reply.id)
    #expect(items[2].url == "https://example.com/q3.png" && items[2].title == "q3")
    #expect(items[3].attachment == photo && items[3].messageID == sent.id)
}

@Test @MainActor func jumpingToAThreadItemOpensTheThread() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jump"); store.bots = [bot]; store.selectedBot = bot
    let thread = ChatThread(parentMessageID: UUID(), parentSessionID: nil, hermesSessionID: "f"); bot.threads = [thread]
    let item = MediaItem(id: "i", kind: .link, title: "t", url: "https://x.example", attachment: nil, messageID: UUID(), threadID: thread.id, date: .now)
    store.jump(to: item)
    #expect(store.openThreadID == thread.id && store.scrollTarget == item.messageID)
    #expect(store.openThread(in: bot) === thread)
}

@Test @MainActor func historyMergeIgnoresSteerBubblesAndImagePlaceholders() throws {
    let user = ChatMessage(role: .user, content: "What is in this?", attachments: [ChatAttachment(id: UUID(), kind: .image, name: "a.png", mimeType: "image/png", byteCount: 1, fileName: "a.png")])
    let answer = ChatMessage(role: .assistant, content: "A cat.")
    let steer = ChatMessage(role: .user, content: "be brief", metadata: ["steer": "sent"])
    let server = [BackendMessage(role: "user", content: "What is in this?\n[Image: data:image/png;base64,AAAA]"), BackendMessage(role: "assistant", content: "A cat."), BackendMessage(role: "assistant", content: "Anything else?")]
    let merged = try #require(AppStore.mergeHermesHistory(local: [user, answer, steer], server: server))
    #expect(merged.last?.content == "Anything else?" && merged.count == 4)
}
