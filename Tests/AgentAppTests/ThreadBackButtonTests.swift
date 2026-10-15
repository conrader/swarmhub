import AppKit
import SwiftUI
import Testing
@testable import AgentApp

// P41 1: the thread's back chevron sits in the chat header's drag strip. Every point of its frame must land on the
// button, never on the strip's `WindowDragView`, and a click at a corner goes back to the chat. Synthetic, off screen.

@MainActor private func hostedThreadChat() async throws -> (AppStore, NSWindow, CGRect) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let parent = ChatMessage(role: .assistant, content: "Parent message")
    let thread = ChatThread(parentMessageID: parent.id, parentSessionID: nil, hermesSessionID: nil,
                            messages: [ChatMessage(role: .user, content: "A thread reply")])
    let bot = Bot(name: "Back fixture"); bot.messages = [parent]; bot.threads = [thread]
    store.bots = [bot]; store.selectedBot = bot; store.openThreadID = thread.id
    let size = NSSize(width: 720, height: 420)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: ChatView(bot: bot).environmentObject(store).defaultAppStorage(store.defaults)
        .frame(width: size.width, height: size.height))
    let window = KeyableWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
    var frame: CGRect?
    try await waitUntil {
        host.layoutSubtreeIfNeeded()
        frame = ChromeProbes.frames(in: window)["thread_back"]
        return frame != nil
    }
    // Probe frames are top-left; AppKit hit-testing is bottom-left.
    let rect = try #require(frame)
    return (store, window, CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
}

/// Takes clicks like the app's window, while staying off every screen.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor private func chain(_ view: NSView?) -> [String] {
    sequence(first: view, next: { $0?.superview }).compactMap { $0.map { String(describing: type(of: $0)) } }
}

@MainActor private func probePoints(_ rect: CGRect) -> [CGPoint] {
    let inset: CGFloat = 1
    return [CGPoint(x: rect.midX, y: rect.midY),
            CGPoint(x: rect.minX + inset, y: rect.minY + inset), CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
            CGPoint(x: rect.minX + inset, y: rect.maxY - inset), CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)]
}

@Test @MainActor func threadBackButtonCornersNeverHitTheDragStrip() async throws {
    let (_, window, rect) = try await hostedThreadChat()
    defer { window.contentView = nil; window.close() }
    #expect(rect.width >= 22 && rect.height >= 22)
    let content = try #require(window.contentView)
    for point in probePoints(rect) {
        let hit = content.hitTest(point)
        #expect(hit != nil, "something answers at \(point)")
        #expect(!chain(hit).contains { $0.contains("WindowDragView") }, "\(point) lands on \(chain(hit))")
    }
}

@Test @MainActor func aClickAtTheBackButtonsCornerClosesTheThread() async throws {
    let (store, window, rect) = try await hostedThreadChat()
    defer { window.contentView = nil; window.close() }
    let corner = CGPoint(x: rect.maxX - 1, y: rect.minY + 1)
    window.orderFrontRegardless(); window.makeKey()
    try await Task.sleep(for: .milliseconds(100))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(with: type, location: corner, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(60))
    }
    try await waitUntil(timeout: .seconds(10)) { store.openThreadID == nil }
}
