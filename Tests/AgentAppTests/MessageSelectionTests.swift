import AppKit
import Foundation
import Testing
@testable import AgentApp

private let ids = (0..<6).map { _ in UUID() }
private let utc = TimeZone(identifier: "UTC")!
private func at(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(minute) * 60) } // 2026-09-21 14:13 UTC
private let appRequest = "[[SWARMHUB_APP_REQUEST_00000000-0000-4000-8000-000000000051]]\n"
    + #"{"action":"execute","tool":"GITHUB_GET_THE_AUTHENTICATED_USER","arguments":{}}"#

/// Records the text input's native Copy action without touching the user's pasteboard.
@MainActor private final class CopyingTextView: NSTextView {
    var copied: String?
    override func copy(_ sender: Any?) { copied = (string as NSString).substring(with: selectedRange()) }
}

struct MessageSelectionTests {
    // ⌘-click toggles a row and makes it the anchor; ⇧-click runs from the anchor.
    @Test func commandClickTogglesRowsAndSetsTheAnchor() {
        var selection = MessageSelectionState()
        #expect(selection.isEmpty && selection.anchor == nil)
        selection.toggle(ids[1]); selection.toggle(ids[4])
        #expect(selection.selected == [ids[1], ids[4]] && selection.anchor == ids[4])
        selection.toggle(ids[1]); #expect(selection.selected == [ids[4]] && selection.anchor == ids[4], "deselecting another row keeps the anchor")
        selection.toggle(ids[4]); #expect(selection.isEmpty && selection.anchor == nil)
    }

    @Test func shiftClickSelectsTheRunFromTheAnchorAndReplacesThePreviousRun() {
        var selection = MessageSelectionState()
        selection.toggle(ids[2])
        selection.extend(to: ids[4], order: ids); #expect(selection.selected == Set(ids[2...4]))
        selection.extend(to: ids[0], order: ids); #expect(selection.selected == Set(ids[0...2]), "upwards, and the earlier run is replaced")
        selection.extend(to: ids[2], order: ids); #expect(selection.selected == [ids[2]] && selection.anchor == ids[2])
    }

    @Test func shiftClickKeepsCommandPickedRowsOutsideTheRun() {
        var selection = MessageSelectionState()
        selection.toggle(ids[0]); selection.toggle(ids[3])
        selection.extend(to: ids[5], order: ids)
        #expect(selection.selected == [ids[0], ids[3], ids[4], ids[5]])
        selection.toggle(ids[1]); selection.extend(to: ids[2], order: ids)
        #expect(selection.selected == [ids[0], ids[1], ids[2], ids[3], ids[4], ids[5]], "a ⌘-click commits the run, a new run starts at the new anchor")
    }

    @Test func shiftClickWithoutAnAnchorPicksTheClickedRowAndClearEmpties() {
        var selection = MessageSelectionState()
        selection.extend(to: ids[3], order: ids); #expect(selection.selected == [ids[3]] && selection.anchor == ids[3])
        selection.extend(to: ids[5], order: ids); #expect(selection.selected == Set(ids[3...5]))
        selection.clear(); #expect(selection == MessageSelectionState())
        selection.toggle(ids[1]); selection.extend(to: UUID(), order: ids)
        #expect(selection.selected.count == 2, "a row not in the transcript order is added without a run")
    }

    @Test func copiedTextIsChronologicalWithAuthorAndTimestamp() {
        let rows = [CopiedMessage(author: "Atlas", date: at(2), text: "Second"),
                    CopiedMessage(author: "Konrad", date: at(0), text: "First\nline two"),
                    CopiedMessage(author: "SwarmHub", date: at(2), text: "Same minute, later in the transcript")]
        #expect(MessageCopy.text(rows, timeZone: utc) == """
        Konrad · 2026-09-21 14:13
        First
        line two

        Atlas · 2026-09-21 14:15
        Second

        SwarmHub · 2026-09-21 14:15
        Same minute, later in the transcript
        """)
        #expect(MessageCopy.text([], timeZone: utc).isEmpty)
        #expect(MessageCopy.text([CopiedMessage(author: "Atlas", date: at(0), text: "")], timeZone: utc) == "Atlas · 2026-09-21 14:13")
    }

    @Test func copiedBodyIsTrimmedAndListsAttachments() {
        #expect(MessageCopy.body("  hello \n\n") == "hello")
        #expect(MessageCopy.body("See this", attachmentNames: ["plan.pdf", "shot.png"]) == "See this\n[Attachment: plan.pdf]\n[Attachment: shot.png]")
        #expect(MessageCopy.body(" ", attachmentNames: ["shot.png"]) == "[Attachment: shot.png]")
        #expect(MessageCopy.menuTitle(count: 1) == "Copy Message" && MessageCopy.menuTitle(count: 3) == "Copy 3 Messages")
    }

    @MainActor @Test func selectionCopiesOnlyPickedRowsStillShownOldestFirst() {
        let messages = [ChatMessage(role: .user, content: "Question", createdAt: at(0)), ChatMessage(role: .assistant, content: "Answer", createdAt: at(1)),
                        ChatMessage(role: .user, content: "Thanks", createdAt: at(3)), ChatMessage(role: .assistant, content: "Arrival", createdAt: at(2))]
        let selection = MessageSelection()
        let describe: (ChatMessage) -> CopiedMessage = { CopiedMessage(author: $0.role == .user ? "Konrad" : "Atlas", date: $0.createdAt, text: $0.content) }
        selection.show(rows: messages, describe: describe)
        #expect(selection.count == 0 && selection.copiedText.isEmpty)
        selection.toggle(messages[2].id); selection.toggle(messages[0].id); selection.toggle(messages[3].id)
        #expect(selection.isSelected(messages[3].id) && !selection.isSelected(messages[1].id) && selection.count == 3)
        let text = selection.copiedText
        #expect(text.components(separatedBy: "\n\n").map { $0.components(separatedBy: "\n").last ?? "" } == ["Question", "Arrival", "Thanks"])
        #expect(text.hasPrefix("Konrad · ") && !text.contains("Answer"))

        selection.extend(to: messages[1].id); #expect(selection.count == 4, "the run from the anchor (Arrival) up to Answer joins the ⌘-picked rows")
        selection.show(rows: Array(messages.prefix(2)), describe: describe)
        #expect(selection.count == 2 && !selection.copiedText.contains("Thanks"), "a row no longer shown is not copied")
        selection.clear(); #expect(selection.count == 0 && selection.state.isEmpty)
    }

    @MainActor @Test func commandCopyDefersToFocusedTextAndFieldEditorsWithoutClearingMessages() throws {
        var copied: [String] = []
        let selection = MessageSelection(copyText: { copied.append($0) })
        let (window, reader) = copyWindow(selection)
        defer { window.contentView = nil; window.close() }
        let row = ChatMessage(role: .assistant, content: "Selected message")
        selection.show(rows: [row]) { CopiedMessage(author: "Atlas", date: $0.createdAt, text: $0.content) }
        selection.toggle(row.id)
        let editor = CopyingTextView(frame: NSRect(x: 0, y: 110, width: 200, height: 80))
        editor.string = "Composer text"; window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor)); editor.setSelectedRange(NSRange(location: 0, length: 8))
        let event = try commandCopyEvent(in: window)
        #expect(selection.handle(event, in: window) === event && copied.isEmpty)
        #expect(editor.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        #expect(editor.copied == "Composer" && selection.count == 1)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(!selection.copyIfAllowed(in: window), "text input keeps Copy even with an insertion point")
        editor.isEditable = false; editor.setSelectedRange(NSRange(location: 0, length: 8))
        #expect(!selection.canCopy(in: window), "read-only selectable text also keeps Copy")

        let field = NSTextField(string: "Field text"); field.frame = NSRect(x: 0, y: 200, width: 200, height: 24)
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field)); field.selectText(nil)
        let fieldEditor = try #require(field.currentEditor())
        #expect(window.firstResponder === fieldEditor && fieldEditor.selectedRange.length > 0)
        #expect(selection.handle(event, in: window) === event && copied.isEmpty && selection.count == 1)

        #expect(window.makeFirstResponder(reader))
        #expect(selection.handle(event, in: nil) === event && copied.isEmpty, "an event without a window is not the transcript's")
        #expect(selection.handle(event, in: window) == nil && copied == [selection.copiedText])
    }

    @MainActor @Test func messageClickFocusesTheNativeCopyTargetAndMenuValidationTracksSelection() throws {
        var copied: [String] = []
        let selection = MessageSelection(copyText: { copied.append($0) })
        let (window, reader) = copyWindow(selection)
        defer { window.contentView = nil; window.close() }
        let row = ChatMessage(role: .assistant, content: "Selected message")
        selection.show(rows: [row]) { CopiedMessage(author: "Atlas", date: $0.createdAt, text: $0.content) }
        selection.place(row.id, reader.bounds); selection.hoverTranscript(true)
        let editor = CopyingTextView(frame: NSRect(x: 0, y: 110, width: 200, height: 80))
        window.contentView?.addSubview(editor); #expect(window.makeFirstResponder(editor))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: reader.convert(NSPoint(x: 10, y: 10), to: nil),
                                                   modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(selection.handle(click, in: window) == nil && window.firstResponder === reader && selection.count == 1)
        let item = NSMenuItem(title: "Copy", action: #selector(MessageSelectionReader.copy(_:)), keyEquivalent: "c")
        #expect(reader.validateUserInterfaceItem(item))
        #expect(window.firstResponder?.tryToPerform(item.action!, with: item) == true)
        #expect(copied == [selection.copiedText], "Edit > Copy and Cmd-C use the same message formatter")
        #expect(window.makeFirstResponder(editor))
        #expect(!reader.validateUserInterfaceItem(item)); reader.copy(item)
        #expect(copied.count == 1, "a stale menu action cannot override text focus")
        #expect(window.makeFirstResponder(reader)); selection.clear()
        #expect(!reader.validateUserInterfaceItem(item)); reader.copy(item)
        #expect(copied.count == 1)
        selection.toggle(row.id)
        let (otherWindow, _) = copyWindow(MessageSelection())
        defer { otherWindow.contentView = nil; otherWindow.close() }
        let otherEvent = try commandCopyEvent(in: otherWindow)
        #expect(selection.handle(otherEvent, in: otherWindow) === otherEvent && !selection.copyIfAllowed(in: otherWindow))
        #expect(copied.count == 1, "other windows cannot copy this transcript's selection")
    }

    @MainActor private func copyWindow(_ selection: MessageSelection) -> (NSWindow, MessageSelectionReader) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let reader = MessageSelectionReader(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        reader.selection = selection; selection.reader = reader
        content.addSubview(reader); window.contentView = content
        return (window, reader)
    }

    @MainActor private func commandCopyEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    }
}
