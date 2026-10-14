import Foundation
import Testing
@testable import AgentApp

// P20: the sidebar's second line, its geometry and the flat list.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func archived(_ text: String, role: String = "assistant", author: String? = nil, seq: Int64 = 1, hidden: Bool = false) -> ArchivedMessage {
    ArchivedMessage(id: "a\(seq)", seq: seq, role: role, author: author, text: text, timestamp: nil, hidden: hidden, channel: "main", to: nil)
}

@Test func fragmentShowsTheNewestBotMessageBare() {
    let messages = [ChatMessage(role: .user, content: "hi"), ChatMessage(role: .assistant, content: "Hello   there\n\nKonrad")]
    #expect(SidebarFragment.text(messages: messages, draft: nil, isWorking: false, archiveNewest: nil) == "Hello there Konrad")
}

@Test func fragmentPrefixesTheUsersOwnMessage() {
    let messages = [ChatMessage(role: .assistant, content: "Done."), ChatMessage(role: .user, content: "Thanks!")]
    #expect(SidebarFragment.text(messages: messages, draft: nil, isWorking: false, archiveNewest: nil) == "You: Thanks!")
}

@Test func fragmentNamesTheGroupMember() {
    let rapper = UUID()
    let messages = [ChatMessage(role: .user, content: "@Rapper go"), ChatMessage(role: .assistant, content: "Yo **check** this", authorID: rapper)]
    let names: (UUID?) -> String? = { $0 == rapper ? "Rapper" : nil }
    #expect(SidebarFragment.text(messages: messages, draft: nil, isWorking: false, archiveNewest: nil, author: names) == "Rapper: Yo check this")
    // Group archive lines carry their own author; one-bot archives stay bare.
    let line = archived("old news", author: "Jarvis")
    #expect(SidebarFragment.text(messages: [], draft: nil, isWorking: false, archiveNewest: line, author: names) == "Jarvis: old news")
    #expect(SidebarFragment.text(messages: [], draft: nil, isWorking: false, archiveNewest: line) == "old news")
}

@Test func fragmentPrefersDraftThenTyping() {
    let messages = [ChatMessage(role: .assistant, content: "Earlier reply")]
    #expect(SidebarFragment.text(messages: messages, draft: "  half a\nthought ", isWorking: true, archiveNewest: nil) == "Draft: half a thought")
    #expect(SidebarFragment.text(messages: messages, draft: "   ", isWorking: true, archiveNewest: nil) == "Typing…")
    #expect(SidebarFragment.text(messages: messages, draft: nil, isWorking: false, archiveNewest: nil) == "Earlier reply")
}

@Test func fragmentFallsBackToTheArchiveOnlyWithoutLiveMessages() {
    let line = archived("From Grok", role: "user")
    #expect(SidebarFragment.text(messages: [], draft: nil, isWorking: false, archiveNewest: line) == "You: From Grok")
    #expect(SidebarFragment.text(messages: [ChatMessage(role: .assistant, content: "live")], draft: nil, isWorking: false, archiveNewest: line) == "live")
    // System notes and empty replies are skipped on the way back.
    let quiet = [ChatMessage(role: .assistant, content: "real"), ChatMessage(role: .system, content: "note"), ChatMessage(role: .assistant, content: "  ")]
    #expect(SidebarFragment.text(messages: quiet, draft: nil, isWorking: false, archiveNewest: line) == "real")
    let lines = [archived("newest hidden", seq: 3, hidden: true), archived("visible", seq: 2), archived("first", seq: 1)].sorted { $0.seq < $1.seq }
    #expect(GrokHistoryStore.newestVisible(in: lines)?.text == "visible")
}

@Test func fragmentStripsMarkdown() {
    let cases = [
        ("# Plan\n- **one** and _two_\n- [docs](https://x.y) `code`", "Plan one and two docs code"),
        ("> quoted *line*\n1. first", "quoted line first"),
        ("```swift\nlet x = 1\n```", "let x = 1"),
        ("![chart](a.png) ~~old~~ snake_case_name", "chart old snake_case_name"),
    ]
    for (input, expected) in cases { #expect(SidebarFragment.plain(input) == expected, "\(input)") }
}

@Test func fragmentHidesTheSwarmhubBlockAndUsesAttachments() {
    let reply = ChatMessage(role: .assistant, content: "Created Scout.\n```swarmhub\n{\"add_bots\":[]}\n```")
    #expect(SidebarFragment.text(messages: [reply], draft: nil, isWorking: false, archiveNewest: nil) == "Created Scout.")
    let file = ChatAttachment(id: UUID(), kind: .image, name: "photo.png", mimeType: "image/png", byteCount: 3)
    #expect(SidebarFragment.text(messages: [ChatMessage(role: .user, content: "", attachments: [file])], draft: nil, isWorking: false, archiveNewest: nil) == "You: Attachment: photo.png")
}

@Test func fragmentIsEmptyWithNothingAtAll() {
    #expect(SidebarFragment.text(messages: [], draft: nil, isWorking: false, archiveNewest: nil) == "")
    #expect(SidebarFragment.text(messages: [], draft: "", isWorking: false, archiveNewest: archived("   ")) == "")
}

@Test func sidebarRowGeometryMatchesTheReference() {
    #expect(SidebarMetrics.rowHeight == 58 && SidebarMetrics.mark == 36 && SidebarMetrics.markGap == 12 && SidebarMetrics.rowPadding == 12)
    #expect(SidebarMetrics.nameSize == 15 && SidebarMetrics.fragmentSize == 14 && SidebarMetrics.selectionRadius == 10)
    #expect(SidebarMetrics.roundButton == 32 && SidebarMetrics.badge == 12)
    #expect(SidebarMetrics.width.min == 240 && SidebarMetrics.width.ideal == 280 && SidebarMetrics.width.max == 320)
    #expect(SidebarMetrics.initial(of: "") == "K" && SidebarMetrics.initial(of: "  ola ") == "O")
}

@Test func sidebarRendersNoSectionLabels() throws {
    for file in ["SidebarView.swift", "SidebarRows.swift"] {
        let source = try String(contentsOf: repoRoot.appending(path: "Sources/AgentApp/Views/\(file)"), encoding: .utf8)
        for label in ["MY BOTS", "GROUPS", "WORKSPACE", "sectionLabel"] { #expect(!source.contains(label), "\(file) has \(label)") }
    }
}

@MainActor @Test func draftsAreKeptPerChat() {
    let drafts = ComposerDrafts(), a = UUID(), b = UUID()
    drafts.set("hello", for: a)
    #expect(drafts.text(for: a) == "hello" && drafts.text(for: b) == "")
    drafts.set("", for: a)
    #expect(drafts.texts[a] == nil)
}
