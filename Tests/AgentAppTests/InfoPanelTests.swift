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
    try #require(host.bounds.height - viewport.height > 150, "The fixed header should include the tabs and bot identity")
    let previewHeight = document.frame.height
    let initialButtons = descendants(document, of: NSButton.self).count

    bot.botDescription += "\n" + String(repeating: "More description.\n", count: 40)
    bot.persona = preview + "\n" + String(repeating: "Keep the relevant context.\n", count: 80)
    try await waitUntil(timeout: .seconds(10)) {
        host.layoutSubtreeIfNeeded()
        return descendants(document, of: NSButton.self).count > initialButtons
    }
    #expect(scroll.convert(scroll.bounds, to: host) == viewport)
    #expect(abs(document.frame.height - previewHeight) <= 2, "Long instructions should occupy the same space as three lines")

    let toggle = try #require(descendants(document, of: NSButton.self).first)
    toggle.performClick(nil)
    try await waitUntil(timeout: .seconds(10)) {
        host.layoutSubtreeIfNeeded()
        return document.frame.height > viewport.height
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
    #expect(scroll.documentVisibleRect.minY > 0)
    #expect(scroll.convert(scroll.bounds, to: host) == viewport)

    scroll.contentView.scroll(to: .zero)
    try #require(descendants(document, of: NSButton.self).first).performClick(nil)
    try await waitUntil(timeout: .seconds(10)) {
        host.layoutSubtreeIfNeeded()
        return document.frame.height <= previewHeight + 2
    }
}

@MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
}
