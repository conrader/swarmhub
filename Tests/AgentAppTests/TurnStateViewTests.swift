import AppKit
import Foundation
import Testing
@testable import AgentApp

// P16 views: the footers and the warning line render; the sidebar badge (P20 item waiting on P16).

@MainActor @Test func footersAndAWarningLineRenderWithoutTouchingTheStore() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Echo", backend: .hermes, hermesProfile: "default", hermesSessionID: "s-echo")
    let ambiguous = ChatMessage(role: .assistant, content: "", metadata: ["why": "timeout", "ambiguous": "1"], turnState: .notSent)
    bot.messages = [
        ChatMessage(role: .user, content: "first synthetic question"), ChatMessage(role: .assistant, content: "", metadata: ["why": "offline"], turnState: .notSent),
        ChatMessage(role: .system, content: "Echo: The Internet connection appears to be offline.", metadata: ["tone": "warning"]),
        ChatMessage(role: .user, content: "second synthetic question"), ambiguous,
        ChatMessage(role: .user, content: "third synthetic question"), ChatMessage(role: .assistant, content: syntheticParagraph(120, seed: 5), turnState: .incomplete),
        ChatMessage(role: .user, content: "fourth synthetic question"),
        ChatMessage(role: .assistant, content: syntheticParagraph(90, seed: 6), metadata: ["restored": "extended"], turnState: .finished),
    ]
    store.bots = [bot]; store.selectedBot = bot; store.save()
    let before = try Data(contentsOf: store.fileURL)
    let png = try #require(await SnapshotRenderer.contentPNG(store: store, size: NSSize(width: 1120, height: 760), scale: 1))
    let image = try #require(NSBitmapImageRep(data: png))
    var colours = Set<String>()
    for x in stride(from: 0, to: image.pixelsWide, by: 12) { for y in stride(from: 0, to: image.pixelsHigh, by: 12) {
        if let c = image.colorAt(x: x, y: y) { colours.insert(String(format: "%.2f%.2f%.2f", c.redComponent, c.greenComponent, c.blueComponent)) }
    } }
    #expect(colours.count > 8, "not blank")
    #expect(try Data(contentsOf: store.fileURL) == before, "rendering never writes the store")
    if let path = ProcessInfo.processInfo.environment["P16_SNAPSHOT"] { try png.write(to: URL(fileURLWithPath: path)) }
    #expect(TurnStateFooter.text(for: ambiguous) == "Not confirmed (timeout) — the box may have it")
}

@MainActor @Test func theSidebarBadgeMarksAFailedOrIncompleteLastTurn() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Echo", backend: .hermes); store.bots = [bot]
    bot.messages = [ChatMessage(role: .user, content: "q"), ChatMessage(role: .assistant, content: "a", turnState: .finished)]
    #expect(!store.needsAttention(bot))
    bot.messages[1].turnState = .notSent
    #expect(store.needsAttention(bot))
    bot.messages[1].turnState = .incomplete
    #expect(store.needsAttention(bot))
    bot.messages[1].isStreaming = true
    #expect(!store.needsAttention(bot), "a reply still streaming is working, not failed")
    bot.messages[1].isStreaming = false; bot.messages[1].turnState = nil
    #expect(!store.needsAttention(bot), "rows written before P16 carry no badge")
}
