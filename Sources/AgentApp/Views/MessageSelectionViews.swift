import AppKit
import SwiftUI

/// Multi-select in one transcript (`MessageSelectionState`): ⌘-click and ⇧-click pick rows, ⌘C or the context menu copies
/// them as plain text (`MessageCopy`), Escape or a plain click in the transcript clears. A local event monitor reads the
/// clicks, so a modified click on a row never starts a text selection and a plain click still selects text as before.
/// Rows report their frames in the transcript content's space and a transparent view there converts the click, so the
/// clicked row is right after a scroll too. Only the transcript's own window counts, so sheets, popovers and other
/// windows keep their clicks and keys. Not observed by the chat itself: only picked rows redraw.
@MainActor final class MessageSelection: ObservableObject {
    nonisolated static let space = "messageSelection"
    @Published private(set) var state = MessageSelectionState()
    /// The transcript content's view (`SelectionReader`): its window, and a click's point in `space`.
    weak var reader: NSView?
    private var rows: [ChatMessage] = []
    private var describe: (ChatMessage) -> CopiedMessage = { CopiedMessage(author: "", date: $0.createdAt, text: MessageCopy.body($0.content)) }
    private var frames: [UUID: CGRect] = [:], inTranscript = false
    private var monitor: Any?, holders = 0

    /// Every body pass: the rows that can be picked (top to bottom) and how each is copied. Never redraws.
    func show(rows: [ChatMessage], describe: @escaping (ChatMessage) -> CopiedMessage) {
        self.rows = rows; self.describe = describe
    }

    func isSelected(_ id: UUID) -> Bool { state.contains(id) }
    /// Picked rows still shown.
    var count: Int { rows.reduce(0) { $0 + (state.contains($1.id) ? 1 : 0) } }
    func toggle(_ id: UUID) { state.toggle(id) }
    func extend(to id: UUID) { state.extend(to: id, order: rows.map(\.id)) }
    func clear() { if !state.isEmpty { state.clear() } }

    /// The picked rows as plain text, oldest first.
    var copiedText: String { MessageCopy.text(rows.filter { state.contains($0.id) }.map(describe)) }
    func copy() {
        let text = copiedText
        if !text.isEmpty { copyToPasteboard(text) }
    }

    /// A laid-out row's frame in `space` (nil: no longer laid out).
    func place(_ id: UUID, _ frame: CGRect?) { frames[id] = frame }
    func hoverTranscript(_ inside: Bool) { inTranscript = inside }

    /// Counted: a transcript recreated for another conversation may appear before the old one disappears.
    func install() {
        holders += 1
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    func remove() {
        holders = max(holders - 1, 0)
        guard holders == 0 else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; inTranscript = false; clear()
    }

    /// The shown row under a click.
    private func row(at event: NSEvent) -> UUID? {
        guard let reader else { return nil }
        let point = reader.convert(event.locationInWindow, from: nil)
        return rows.first { frames[$0.id]?.contains(point) ?? false }?.id
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = reader?.window, event.window === window else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        switch event.type {
        case .keyDown:
            guard count > 0 else { return event }
            if event.keyCode == 53 { clear(); return nil } // Escape
            if flags == .command, event.charactersIgnoringModifiers == "c" { copy(); return nil }
            return event
        case .rightMouseDown: return menu(event)
        case .leftMouseDown:
            if flags.contains(.control) { return menu(event) }
            guard flags.contains(.command) || flags.contains(.shift) else {
                if inTranscript { clear() }
                return event
            }
            guard inTranscript, let id = row(at: event) else { return event }
            if flags.contains(.shift) { extend(to: id) } else { toggle(id) }
            return nil
        default: return event
        }
    }

    /// A right-click on a picked row: Copy and Deselect. Elsewhere the usual menu.
    private func menu(_ event: NSEvent) -> NSEvent? {
        guard inTranscript, let id = row(at: event), state.contains(id), let view = event.window?.contentView else { return event }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(MessageCopy.menuTitle(count: count), key: "c") { [weak self] in self?.copy() })
        menu.addItem(ActionMenuItem("Deselect Messages") { [weak self] in self?.clear() })
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return nil
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, key: String = "", run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: nil, keyEquivalent: key)
        action = #selector(fire); target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func fire() { run() }
}

/// Behind the transcript content, the size of `MessageSelection.space`: flipped like SwiftUI and never hit.
private struct SelectionReader: NSViewRepresentable {
    let selection: MessageSelection
    func makeNSView(context: Context) -> Reader { let view = Reader(); selection.reader = view; return view }
    func updateNSView(_ view: Reader, context: Context) { selection.reader = view }
    final class Reader: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A picked row: tinted with the accent, outlined. Every row reports its frame.
private struct SelectableMessageRow: ViewModifier {
    let id: UUID; @ObservedObject var selection: MessageSelection
    func body(content: Content) -> some View {
        let picked = selection.isSelected(id)
        content
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor.opacity(0.45), lineWidth: 1))
                        .padding(.horizontal, 14)
                }
            }
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(MessageSelection.space))
                    Color.clear.onAppear { selection.place(id, frame) }.onChange(of: frame) { _, frame in selection.place(id, frame) }
                        .onDisappear { selection.place(id, nil) }
                }
            }
            .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

extension View {
    /// A transcript row ⌘-click and ⇧-click can pick.
    func selectableMessage(_ id: UUID, in selection: MessageSelection) -> some View {
        modifier(SelectableMessageRow(id: id, selection: selection))
    }
    /// The transcript content whose rows `selection` picks (inside the scroll view, around the rows).
    func messageSelectionContent(_ selection: MessageSelection) -> some View {
        coordinateSpace(.named(MessageSelection.space)).background(SelectionReader(selection: selection))
    }
    /// The scroll view: whether the pointer is over it, and the event monitor while it is shown.
    func messageSelection(_ selection: MessageSelection) -> some View {
        onHover { selection.hoverTranscript($0) }
            .onAppear { selection.install() }.onDisappear { selection.remove() }
    }
}
