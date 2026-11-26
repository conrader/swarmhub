import AppKit
import SwiftUI
import Testing
@testable import AgentApp

@Test @MainActor func botDetailsFoldLongInstructionsInsideThePinnedHeader() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let preview = "Collect the sources.\nCheck their dates.\nSummarize the findings."
    let bot = Bot(name: "Research Bot", description: "Researches new topics.", persona: preview)
    let size = NSSize(width: 330, height: 360)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: InfoPanel(bot: bot).environmentObject(store).frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }

    try await waitUntil(timeout: .seconds(10)) {
        host.layoutSubtreeIfNeeded()
        return descendants(host, of: NSScrollView.self).first?.documentView != nil
    }
    let scroll = try #require(descendants(host, of: NSScrollView.self).first)
    let document = try #require(scroll.documentView)
    let viewport = scroll.convert(scroll.bounds, to: host)
    try #require(host.bounds.height - viewport.height > 120, "The fixed header should include the tabs and bot identity")
    let previewHeight = document.frame.height
    let initialButtons = descendants(document, of: NSButton.self).count

    bot.botDescription += "\n" + String(repeating: "More description.\n", count: 40)
    bot.persona = preview + "\n" + String(repeating: "Keep the relevant context.\n", count: 80)
    try await waitUntil(timeout: .seconds(10)) {
        host.layoutSubtreeIfNeeded()
        return descendants(document, of: NSButton.self).count > initialButtons
    }
    expectSameViewport(scroll.convert(scroll.bounds, to: host), viewport)
    #expect(abs(document.frame.height - previewHeight) <= 2, "Long instructions should occupy the same space as three lines")

    let toggle = try #require(descendants(document, of: NSButton.self).first)
    toggle.performClick(nil)
    try await waitUntil(timeout: .seconds(10)) {
        host.layoutSubtreeIfNeeded()
        return document.frame.height > viewport.height
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
    #expect(scroll.documentVisibleRect.minY > 0)
    expectSameViewport(scroll.convert(scroll.bounds, to: host), viewport)

    scroll.contentView.scroll(to: .zero)
    try #require(descendants(document, of: NSButton.self).first).performClick(nil)
    try await waitUntil(timeout: .seconds(10)) {
        host.layoutSubtreeIfNeeded()
        return document.frame.height <= previewHeight + 2
    }
}

private func expectSameViewport(_ actual: NSRect, _ expected: NSRect, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(actual.origin.x - expected.origin.x) <= 1, sourceLocation: sourceLocation)
    #expect(abs(actual.origin.y - expected.origin.y) <= 1, sourceLocation: sourceLocation)
    #expect(abs(actual.width - expected.width) <= 1, sourceLocation: sourceLocation)
    #expect(abs(actual.height - expected.height) <= 1, sourceLocation: sourceLocation)
}

@MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
}

@MainActor @Test func narrowChatShowsTheLaunchModelAndPendingDirectTurnTogether() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in MockBackend() },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "GameDev", backend: .herdr)
    store.bots = [bot]
    store.open(bot)
    var reading = HerdrAgentReading(templates: [], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: [])
    reading.running = .model(id: "before", label: "Sonnet")
    reading.model = .init(id: "after", label: "Sol")
    store.herdrAgentReadings[bot.id] = reading
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    let data = try #require(await HeadlessSetup.png(ChatView(bot: bot), store: store, updater: updater,
                                                    size: NSSize(width: 500, height: 400)))
    let image = try #require(NSBitmapImageRep(data: data)?.cgImage)
    let text = try await recognizedLines(in: image).joined(separator: " ")
    #expect(text.contains("Sonnet") && text.contains("Sol"), "Both model names should fit the minimum chat width: \(text)")
}
