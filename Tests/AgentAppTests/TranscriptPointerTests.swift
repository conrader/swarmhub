import AppKit
import SwiftUI
import Testing
@testable import AgentApp

/// Opt in on a logged-in Mac. Events go through NSApplication and the actual chat
/// windows. The test intentionally exercises the system pasteboard; it never sends.
@MainActor struct TranscriptPointerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWARMHUB_POINTER_QA"] == "1"))
    func dragAndCopyInBothTranscripts() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftPM's test host has no application Edit menu for the native composer.
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }
        for group in [false, true] { try await exercise(group: group) }
    }

    private func exercise(group: Bool) async throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let old = (0..<96).map { String(format: "History %03d", $0) }
        let rows = old.map { ChatMessage(role: .user, content: $0) } + [
            ChatMessage(role: .assistant, content: SelectionFixture.markdown),
            ChatMessage(role: .user, content: "Closing sentinel")
        ]
        let bot = Bot(name: "Selection fixture", messages: rows)
        let team = GroupChat(name: "Selection group", memberIDs: [bot.id], messages: rows)
        rows[old.count].authorID = bot.id
        store.bots = [bot]
        store.groups = [team]
        let chat = group ? AnyView(GroupChatView(group: team)) : AnyView(ChatView(bot: bot))
        let host = NSHostingView(rootView: chat.environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 20, y: 30, width: 760, height: 660),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.title = group ? "Group selection fixture" : "Direct selection fixture"
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        func visible(_ string: String) -> TranscriptTextView? {
            descendants(host, of: TranscriptTextView.self).first { $0.string == string && !$0.visibleRect.isEmpty }
        }
        func copy() throws -> String? {
            let change = NSPasteboard.general.changeCount
            try key("c", in: window)
            #expect(NSPasteboard.general.changeCount > change)
            return NSPasteboard.general.string(forType: .string)
        }

        try await waitUntil(timeout: .seconds(12)) { visible("Alpha checks the queue") != nil && visible("Closing sentinel") != nil && window.isKeyWindow }
        // Let the production viewport's repeated opening scroll finish.
        try await Task.sleep(for: .milliseconds(300))
        let bullet = try #require(visible("Alpha checks the queue"))
        let closing = try #require(visible("Closing sentinel"))
        let a = try insertion(6, in: bullet), b = try insertion(7, in: closing)
        let suffix = "checks the queue\n• Beta checks the log\n\nlet count = 2\n\nOwner\tState\nAda\tReady\n\nClosing"
        for (start, finish) in [(a, b), (b, a)] {
            try mouse(.leftMouseDown, at: start, in: window)
            try mouse(.leftMouseDragged, at: finish, in: window)
            try mouse(.leftMouseUp, at: finish, in: window)
            #expect(bullet.selectedRange() == NSRange(location: 6, length: 16))
            #expect(closing.selectedRange() == NSRange(location: 0, length: 7))
            #expect(try copy() == suffix)
        }

        // Start in the last user message, hold the pointer at the upper edge until
        // the oldest lazy row mounts, then release inside that row.
        let reader = try #require(descendants(host, of: MessageSelectionReader.self).first)
        let clip = try #require(reader.enclosingScrollView?.contentView)
        let viewport = clip.convert(clip.bounds, to: nil)
        try mouse(.leftMouseDown, at: b, in: window)
        try mouse(.leftMouseDragged, at: CGPoint(x: viewport.midX, y: viewport.maxY - 1), in: window)
        defer { reader.selection?.clear() }
        try await waitUntil(timeout: .seconds(25)) {
            guard let view = visible(old[0]) else { return false }
            return view.visibleRect.contains(view.bounds.insetBy(dx: 1, dy: 1))
        }
        let oldest = try #require(visible(old[0]))
        let end = try insertion(8, in: oldest)
        try mouse(.leftMouseDragged, at: end, in: window)
        try mouse(.leftMouseUp, at: end, in: window)
        let contents = (old + [SelectionFixture.visible, "Closing sentinel"]).joined(separator: "\n\n")
        #expect(try copy() == String(contents.dropFirst(8).dropLast(" sentinel".count)))
        try key("a", in: window)
        #expect(try copy() == contents)

        // A focused, real composer keeps both native shortcuts and its insertion point.
        let editor = try #require(descendants(host, of: NSTextView.self).first { $0.isEditable && !$0.isFieldEditor })
        #expect(window.makeFirstResponder(editor))
        editor.string = "Composer only"
        try key("a", in: window)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 13))
        #expect(try copy() == "Composer only")
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        var found = (root as? T).map { [$0] } ?? []
        for child in root.subviews { found += descendants(child, of: type) }
        return found
    }

    /// An actual pointer position on the leading half of the glyph at this UTF-16 offset.
    private func insertion(_ offset: Int, in view: TranscriptTextView) throws -> CGPoint {
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: offset)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let p = CGPoint(x: view.textContainerOrigin.x + rect.minX + 0.1, y: view.textContainerOrigin.y + rect.midY)
        #expect(view.visibleRect.contains(p))
        #expect(view.characterIndexForInsertion(at: p) == offset)
        return view.convert(p, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint, in window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        NSApp.sendEvent(event)
    }

    private func key(_ char: String, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: char == "c" ? 8 : 0))
        NSApp.sendEvent(event)
    }
}
