import Foundation
import Testing
@testable import AgentApp

/// P19 item 2: every text that goes out is split under Hermes's silent 65,536-code-point cut, so that the
/// server's `\n` join reproduces it. Bodies are captured at the URLProtocol layer.

/// Text whose scalar, UTF-16 and grapheme counts all differ: emoji (2 UTF-16 units), a flag (2 scalars,
/// 1 grapheme) and combining accents.
private func mixedText(scalars: Int, lineEvery: Int? = 80, spaces: Bool = true) -> String {
    let words = ["zażółć", "e\u{301}cole", "🙂", "🇵🇱", "gęślą", "jaźń", "naïve", "x"]
    var out = String.UnicodeScalarView(); var count = 0; var line = 0; var index = 0
    while count < scalars {
        let word = Array(words[index % words.count].unicodeScalars); index += 1
        out.append(contentsOf: word); count += word.count + 1; line += word.count
        if let lineEvery, line >= lineEvery { out.append("\n"); line = 0 } else if spaces { out.append(" ") } else { count -= 1 }
    }
    return String(out)
}

private func scalarCount(_ value: Any?) -> [Int] {
    if let text = value as? String { return [text.unicodeScalars.count] }
    return (value as? [[String: Any]] ?? []).compactMap { ($0["text"] as? String)?.unicodeScalars.count }
}

/// What Hermes makes of a `content` value: text parts joined with `\n` (`_normalize_multimodal_content`).
private func serverText(_ value: Any?) -> String {
    if let text = value as? String { return text }
    return (value as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
}

/// No `file`/`input_file` part, no non-image `data:` URL, anywhere in a body.
private func onlyTextAndImageParts(_ value: Any) -> Bool {
    if let object = value as? [String: Any] {
        if let type = object["type"] as? String, !["text", "image_url"].contains(type) { return false }
        if let url = (object["image_url"] as? [String: Any])?["url"] as? String, url.hasPrefix("data:"), !url.hasPrefix("data:image/") { return false }
        return object.values.allSatisfy(onlyTextAndImageParts)
    }
    if let array = value as? [Any] { return array.allSatisfy(onlyTextAndImageParts) }
    if let text = value as? String { return !text.hasPrefix("data:") || text.hasPrefix("data:image/") }
    return true
}

private func checkShape(_ host: String) {
    let requests = ChatParityServer.requests(host)
    #expect(!requests.contains { $0.path.contains("/v1/artifacts") })
    #expect(requests.allSatisfy { $0.body.map(onlyTextAndImageParts) ?? true })
}

@Test func ourLimitsSitUnderTheServerLimits() {
    #expect(HermesBackend.maxTextPartScalars < HermesServerLimits.maxNormalizedTextLength)
    #expect(HermesBackend.maxRequestBodyBytes < HermesServerLimits.maxRequestBytes)
    // 9.5 MB of text needs at most ~160 parts, far below the 1,000-part cap.
    #expect(HermesBackend.maxRequestBodyBytes / HermesBackend.maxTextPartScalars < HermesServerLimits.maxContentListSize)
}

@Test func splitterCutsAtLineBreaksThenSpacesThenHard() {
    let limit = HermesBackend.maxTextPartScalars
    let short = mixedText(scalars: 1_000)
    #expect(HermesBackend.splitText(short) == [short])
    #expect(HermesBackend.contentParts(text: short, images: []) as? String == short, "short text stays a plain string")

    for text in [mixedText(scalars: 130_000), mixedText(scalars: 130_000, lineEvery: nil)] {
        let pieces = HermesBackend.splitText(text)
        #expect(pieces.count == 3 && pieces.allSatisfy { $0.unicodeScalars.count <= limit && !$0.isEmpty })
        #expect(pieces.joined(separator: "\n") == text || pieces.joined(separator: " ") == text)
        #expect(text.unicodeScalars.count != text.utf16.count && text.count != text.unicodeScalars.count, "the fixture tells the three counts apart")
    }
    let lines = mixedText(scalars: 130_000)
    #expect(HermesBackend.splitText(lines).joined(separator: "\n") == lines, "line-break cuts rejoin exactly")
    let spaced = mixedText(scalars: 130_000, lineEvery: nil)
    let spacedPieces = HermesBackend.splitText(spaced)
    #expect(spacedPieces.joined(separator: " ") == spaced, "space cuts drop exactly one space")

    let solid = String(repeating: "é🙂", count: 70_000)
    let hard = HermesBackend.splitText(solid)
    #expect(hard.count == 3 && hard.allSatisfy { $0.unicodeScalars.count <= limit } && hard.joined() == solid, "hard cuts lose nothing")
    #expect(AppStore.sameText(solid, hard.joined(separator: "\n")), "the server's extra \\n still reconciles")
    #expect(!AppStore.sameText("short a", "short\na"), "short texts compare exactly")
}

@Test func longTextSplitsOnTheSessionStreamWithImages() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in .sse([("run.completed", ["run_id": "r"])]) }
    let text = mixedText(scalars: 130_000)
    let image = "data:image/png;base64,iVBORw0KGgo="
    for try await _ in try await backend.send(.init(sessionID: "s1", systemPrompt: "p", messages: [(role: "user", content: text)], images: [image])) {}
    let body = try #require(ChatParityServer.requests(host).first { $0.path == "/api/sessions/s1/chat/stream" }?.body)
    let parts = try #require(body["input"] as? [[String: Any]])
    #expect(parts.map { $0["type"] as? String } == ["text", "text", "text", "image_url"])
    #expect(scalarCount(parts).allSatisfy { $0 <= HermesBackend.maxTextPartScalars })
    #expect(serverText(parts) == text)
    checkShape(host)
}

@Test func legacyHistoryMessagesAreSplitToo() async throws {
    // P16: EOF without a terminal event is a break, so the legacy fixture ends with `[DONE]` like a real stream.
    let (host, backend) = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: [DONE]\n\n".utf8)) }
    let earlier = mixedText(scalars: 125_000), latest = mixedText(scalars: 61_000, lineEvery: nil)
    let messages: [(role: String, content: String)] = [(role: "user", content: earlier), (role: "assistant", content: "ok"), (role: "user", content: latest)]
    for try await _ in try await backend.send(.init(sessionID: "s1", systemPrompt: "persona", messages: messages)) {}
    let body = try #require(ChatParityServer.requests(host).first { $0.path == "/v1/chat/completions" }?.body)
    let sent = try #require(body["messages"] as? [[String: Any]])
    #expect(sent[0]["content"] as? String == "persona", "the persona stays one string")
    #expect(sent.allSatisfy { scalarCount($0["content"]).allSatisfy { $0 <= HermesBackend.maxTextPartScalars } })
    #expect(serverText(sent[1]["content"]) == earlier && sent[2]["content"] as? String == "ok")
    #expect((sent[3]["content"] as? [[String: Any]])?.count == 2)
    checkShape(host)
}

@Test func oversizedBodiesAreRefusedBeforeSending() async throws {
    let (host, backend) = ChatParityServer.serve(features: [:]) { _, _ in .sse([]) }
    // 4 UTF-8 bytes per scalar keeps the fixture cheap: ~10.2 MB of JSON from 3 million scalars.
    let huge = String(repeating: "🙂🙂🙂🙂 ", count: 600_000)
    await #expect(throws: (any Error).self) { _ = try await backend.send(.init(sessionID: "s1", systemPrompt: "p", messages: [(role: "user", content: huge)])) }
    do { _ = try await backend.send(.init(sessionID: "s1", systemPrompt: "p", messages: [(role: "user", content: huge)])) }
    catch { #expect(error.localizedDescription == HermesBackend.requestTooLargeMessage) }
    #expect(!ChatParityServer.requests(host).contains { $0.path == "/v1/chat/completions" })
}

@MainActor private func hermesStore(features: [String: Bool]) -> (AppStore, Bot, String) {
    let (host, backend) = ChatParityServer.serve(features: features) { request, _ in
        request.url?.path == "/api/sessions" ? .json(200, ["session": ["id": "created"]]) : .sse([("run.completed", ["run_id": "r"])])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: namedDefaults())
    let bot = Bot(name: "Splitter", backend: .hermes, hermesProfile: "default")
    store.bots = [bot]; store.selectedBot = bot
    return (store, bot, host)
}

@Test @MainActor func aLongPDFTurnThenASecondTurnKeepsLegacyHistoryUnderTheLimit() async throws {
    let (store, bot, host) = hermesStore(features: [:])
    let pdfText = "PDF: 40 pages, text extracted\n\n" + mixedText(scalars: 120_000)
    let pdf = ChatAttachment(id: UUID(), kind: .text, name: "POZNAN-synthetic.pdf", mimeType: "application/pdf", byteCount: 900_000, text: pdfText, pageCount: 40, summary: "PDF: 40 pages, text extracted")
    let notes = ChatAttachment(id: UUID(), kind: .text, name: "notes.txt", mimeType: "text/plain", byteCount: 130_000, text: mixedText(scalars: 130_000))
    #expect(store.send(text: "Summarise these", attachments: [pdf, notes]))
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.send(text: "And the totals?"))
    try await waitUntil { !store.anyTurnRunning && ChatParityServer.requests(host).filter { $0.path == "/v1/chat/completions" }.count == 2 }
    let bodies = ChatParityServer.requests(host).filter { $0.path == "/v1/chat/completions" }.compactMap(\.body)
    let second = try #require(bodies.last?["messages"] as? [[String: Any]])
    #expect(second.allSatisfy { scalarCount($0["content"]).allSatisfy { $0 <= HermesBackend.maxTextPartScalars } })
    let firstTurn = try #require(bot.messages.first)
    #expect(serverText(second[1]["content"]) == firstTurn.outgoingText, "the 130,000-character text file and the PDF arrive whole")
    #expect(AppStore.sameText(firstTurn.outgoingText, serverText(second[1]["content"])))
    checkShape(host)
}

@Test @MainActor func groupContextGoesThroughTheSplitterOnTheSessionStream() async throws {
    let (store, bot, host) = hermesStore(features: ["session_chat_streaming": true])
    let other = Bot(name: "Second", backend: .hermes, hermesProfile: "default"); store.bots.append(other)
    let group = try #require(store.createGroup(name: "Split group", memberIDs: [bot.id, other.id]))
    let notes = ChatAttachment(id: UUID(), kind: .text, name: "big.txt", mimeType: "text/plain", byteCount: 130_000, text: mixedText(scalars: 130_000))
    #expect(store.send(text: "Read this", attachments: [notes], to: group))
    try await waitUntil { !store.anyTurnRunning }
    let bodies = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.compactMap(\.body)
    #expect(bodies.count == 2, "each member gets the group context")
    // The current message's attachments are exempt from the 8,000-character cap and go through the splitter.
    for body in bodies {
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 3 && scalarCount(input).allSatisfy { $0 <= HermesBackend.maxTextPartScalars })
        #expect(serverText(input).contains("Konrad: Read this\n\n" + AttachmentEncoder.compose(text: "", attachments: [notes])), "the 130,000-character file arrives whole")
    }
    checkShape(host)
}

@Test @MainActor func aThirtyThousandCharacterDocumentReachesEveryGroupMemberWhole() async throws {
    let (store, bot, host) = hermesStore(features: ["session_chat_streaming": true])
    let other = Bot(name: "Second", backend: .hermes, hermesProfile: "default"); store.bots.append(other)
    let group = try #require(store.createGroup(name: "Doc group", memberIDs: [bot.id, other.id]))
    group.messages = (0..<40).map { ChatMessage(role: .user, content: "earlier \($0) " + String(repeating: "x", count: 400)) }
    let docText = "DOCX: 12 pages, text extracted\n\n" + mixedText(scalars: 30_000)
    let doc = ChatAttachment(id: UUID(), kind: .text, name: "umowa.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                             byteCount: 80_000, text: docText, pageCount: 12, summary: "DOCX: 12 pages, text extracted")
    #expect((30_000..<HermesBackend.maxTextPartScalars).contains(docText.unicodeScalars.count))
    #expect(store.send(text: "Check this contract", attachments: [doc], to: group))
    try await waitUntil { !store.anyTurnRunning }
    let bodies = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.compactMap(\.body)
    #expect(bodies.count == 2, "every member is asked")
    let block = AttachmentEncoder.compose(text: "", attachments: [doc])
    for body in bodies {
        let input = try #require(body["input"] as? String, "under 60,000 scalars the context stays one plain string")
        #expect(input.hasSuffix("Konrad: Check this contract\n\n" + block), "the document arrives whole after the message")
        let history = input.replacingOccurrences(of: "\n\n" + block, with: "")
        #expect(history.count <= GroupRouting.contextLimit && history.contains("[… earlier messages omitted]"), "earlier history stays capped")
        #expect(history.contains("Konrad: earlier 39 ") && !history.contains("Konrad: earlier 0 "))
    }
    checkShape(host)
}

@Test func reconcileMatchesAServerRowBuiltFromSplitParts() async throws {
    let solid = ChatAttachment(id: UUID(), kind: .text, name: "solid.txt", mimeType: "text/plain", byteCount: 1, text: String(repeating: "ż🙂", count: 50_000))
    let outgoing = AttachmentEncoder.compose(text: "Look", attachments: [solid])
    let parts = try #require(HermesBackend.contentParts(text: outgoing, images: []) as? [[String: Any]])
    let row = try #require(HermesBackend.normalizedContent(parts))
    #expect(row != outgoing, "a hard cut adds a line break on the server")
    #expect(AppStore.sameText(outgoing, row))
    let count = await MainActor.run {
        let local = ChatMessage(role: .user, content: "Look", attachments: [solid])
        let merged = AppStore.mergeHermesHistory(local: [local, ChatMessage(role: .assistant, content: "Done")],
                                                 server: [.init(role: "user", content: row), .init(role: "assistant", content: "Done"), .init(role: "assistant", content: "Later")])
        return merged.map { "\($0.count) \($0.last?.content ?? "")" }
    }
    #expect(count == "3 Later")
}
