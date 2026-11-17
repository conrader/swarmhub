import AppKit
import SwiftUI

/// Text, attachments (paperclip, drag-and-drop on the chat, paste) and Send/Stop. While a turn streams, Send never
/// stops it (uxfix1): it steers the turn when the server supports `run_steer`, else the message waits and goes when the
/// turn ends. Stop stays a separate button.
struct ComposerView: View {
    @Binding var text: String; @Binding var attachments: [ChatAttachment]
    let isStreaming: Bool; var canSteer = false
    /// P28 D2: a one-time caption under the composer after the first steer.
    var hint: String? = nil
    let send: () -> Void; let stop: () -> Void
    var attach: ([URL]) -> Void = { _ in }; var pasteImage: (Data, String) -> Void = { _, _ in }
    /// P19: files still being read ("Reading PDF…" chips; Send waits for them) and chip removal.
    var reading: [AttachmentIntake.Reading] = []; var cancelReading: (UUID) -> Void = { _ in }
    var removeAttachment: ((ChatAttachment) -> Void)? = nil
    /// Group chats: member names offered when the user types `@` (Return or Tab picks the first).
    var mentionNames: [String] = []
    /// P22: the manager bot's chat offers the Manage bots menu (each item fills this composer with a plain request).
    var manageActions: [ManageBotsAction] = []; var manage: (ManageBotsAction) -> Void = { _ in }
    /// The setup wizard ends in a chat with the keyboard in its composer: true asks for it, and `tookFocus` says it happened.
    var wantsFocus = false; var tookFocus: () -> Void = {}
    /// Who the message goes to (a bot's or a group's name), for the placeholder.
    var recipient: String? = nil
    @State private var importing = false; @State private var pasteMonitor: Any?; @FocusState private var focused: Bool
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    private var suggestions: [String] {
        guard !mentionNames.isEmpty, let partial = GroupRouting.typedMention(in: text) else { return [] }
        return Array(GroupRouting.suggestions(for: partial, names: mentionNames).prefix(6))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { name in
                        Button { text = GroupRouting.complete(text, with: name) } label: { Text("@" + name).font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(name == suggestions.first ? AnyShapeStyle(AppColor.onAccent) : AnyShapeStyle(.primary))
                            .background(name == suggestions.first ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(4).background(AppColor.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColor.separator, lineWidth: 0.5)).frame(maxWidth: 260)
            }
            if !attachments.isEmpty || !reading.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentTile(attachment: attachment, size: 64) { if let removeAttachment { removeAttachment(attachment) } else { attachments.removeAll { $0.id == attachment.id } } }
                        }
                        ForEach(reading) { item in ReadingChip(label: item.label) { cancelReading(item.id) } }
                    }
                }
            }
            // One row of 28 pt slots: each control is centred in its slot (the `+` menu is drawn by AppKit and ignores its
            // label's frame), and the slots sit on the draft's last line as it grows.
            HStack(alignment: .bottom, spacing: ComposerMetrics.spacing) {
                Button { importing = true } label: { Image(systemName: "paperclip").frame(width: ComposerMetrics.control, height: ComposerMetrics.control).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Attach images or documents")
                    .composerSlot("composer_attach")
                if !manageActions.isEmpty { ManageBotsMenu(actions: manageActions, perform: manage) { Image(systemName: "plus") }.composerSlot("composer_manage") }
                input.chromeProbe("composer_input")
                if isStreaming && hasContent {
                    Button(action: send) { Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(ComposerRoundButtonStyle(prominent: false)).help(canSteer ? "Send now, into this answer" : "Send when this answer ends")
                        .disabled(!reading.isEmpty).composerSlot("composer_steer")
                }
                if isStreaming {
                    Button(action: stop) { Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(ComposerRoundButtonStyle(prominent: true)).help("Stop")
                        .composerSlot("composer_send")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(ComposerRoundButtonStyle(prominent: true)).disabled(!hasContent || !reading.isEmpty)
                        .composerSlot("composer_send")
                }
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).padding(.leading, ComposerMetrics.control + ComposerMetrics.spacing) }
        }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16).stroke(AppColor.separator, lineWidth: 0.5))
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14).frame(maxWidth: 768)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                attach(urls); scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            .onAppear(perform: installPasteMonitor).onDisappear { removePasteMonitor() }
            .onAppear(perform: takeFocus).onChange(of: wantsFocus) { _, _ in takeFocus() }
    }

    /// The draft, sized by a hidden copy of its text (wrapped lines included): one line fills a 28 pt slot with the line
    /// centred, more lines grow it up to `ComposerMetrics.maxInput`, then the editor scrolls. The placeholder sits where
    /// the first typed line does.
    private var input: some View {
        Text(ComposerMetrics.sizingText(text)).font(.body)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, ComposerMetrics.linePadding)
            .padding(.vertical, ComposerMetrics.textInset).hidden()
            .frame(minHeight: ComposerMetrics.control, maxHeight: ComposerMetrics.maxInput).fixedSize(horizontal: false, vertical: true)
            .overlay {
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(isStreaming ? (canSteer ? SteerCopy.placeholder : SteerCopy.queuePlaceholder) : "Message " + (recipient ?? AppConstants.name) + "…").font(.body).foregroundStyle(.tertiary).lineLimit(1)
                                .allowsHitTesting(false).padding(.top, ComposerMetrics.editorInset).padding(.leading, ComposerMetrics.linePadding)
                        }
                    }
                    .padding(.vertical, ComposerMetrics.textInset - ComposerMetrics.editorInset).focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if let first = suggestions.first { text = GroupRouting.complete(text, with: first); return .handled }
                        if reading.isEmpty { send() }; return .handled
                    }
                    .onKeyPress(.tab) { guard let first = suggestions.first else { return .ignored }; text = GroupRouting.complete(text, with: first); return .handled }
            }
    }

    /// The window that asked (the setup wizard) is still closing, and a field only takes the keyboard in the key
    /// window, so the request is answered a moment later.
    private func takeFocus() {
        guard wantsFocus else { return }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); focused = true; tookFocus() }
    }

    /// TextEditor handles text paste itself, so files/images on the pasteboard are intercepted at key-down.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v",
                  let item = PasteboardAttachments.item() else { return event }
            switch item {
            case .files(let urls): attach(urls)
            case .image(let data, let name): pasteImage(data, name)
            }
            return nil
        }
    }
    private func removePasteMonitor() { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil }
}

/// The composer row's geometry (`ComposerLayoutTests` checks it on rendered pixels).
enum ComposerMetrics {
    /// Every control's slot, and the draft's height at one line.
    static let control: CGFloat = 28
    static let spacing: CGFloat = 7
    /// The draft's tallest size (about eight lines); beyond it the editor scrolls.
    static let maxInput: CGFloat = 140
    /// Space above the first line and below the last: (28 − a 16 pt body line) / 2.
    static let textInset: CGFloat = 6
    /// Where the editor's text view draws its first line below its own top, and the gap before each line (NSTextView's
    /// line fragment padding); the placeholder and the sizing text use the same offsets.
    static let editorInset: CGFloat = 0
    static let linePadding: CGFloat = 5

    /// What the hidden sizing text shows: an empty draft still takes one line, and a trailing newline its own line.
    static func sizingText(_ text: String) -> String { text.isEmpty || text.hasSuffix("\n") ? text + " " : text }
}

/// Send, Stop and Add to this answer: a 28 pt circle drawn here, so it fills its slot exactly (the AppKit round bezels
/// size themselves and overflowed it). Prominent is the accent with a glyph in the colour that reads on it.
private struct ComposerRoundButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(AppColor.onAccent) : AnyShapeStyle(.primary))
            .frame(width: ComposerMetrics.control, height: ComposerMetrics.control)
            .background(Circle().fill(prominent ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.quaternary)))
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.3)
    }
}

/// A fixed control slot, reported to `--ui-smoke` and the layout tests as `probe`.
private extension View {
    func composerSlot(_ probe: String) -> some View {
        frame(width: ComposerMetrics.control, height: ComposerMetrics.control).chromeProbe(probe)
    }
}

/// A file still being read: text only (no spinner, no animation); the remove button cancels the read.
private struct ReadingChip: View {
    let label: String; let cancel: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.richtext").foregroundStyle(.secondary)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Button(action: cancel) { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("Stop reading")
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColor.separator, lineWidth: 0.5))
    }
}
