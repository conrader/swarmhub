import AppKit
import SwiftUI

/// The active composer submits guidance to its current turn. Stop is a separate control.
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
    var goalCommand: (SlashCommand) -> String? = { _ in "Goals require a writable workspace bot chat." }
    @State private var slashMenu = SlashMenu()
    @State private var commandNotice: String?
    @State private var noticeDraft: String?
    @State private var importing = false; @State private var editorMonitor: Any?; @FocusState private var focused: Bool
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    private var suggestions: [String] {
        guard !mentionNames.isEmpty, let partial = GroupRouting.typedMention(in: text) else { return [] }
        return Array(GroupRouting.suggestions(for: partial, names: mentionNames).prefix(6))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !slashMenu.choices(for: text).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(slashMenu.choices(for: text), id: \.self) { command in
                        let selected = command == slashMenu.selection(for: text)
                        Button { insert(command) } label: {
                            HStack {
                                Text(command.rawValue).bold()
                                Text(command.usage)
                            }
                            .padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(command.rawValue + " " + command.usage)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint("Insert into message")
                    }
                }.font(.callout).accessibilityElement(children: .contain).accessibilityLabel("Chat commands")
            } else if !suggestions.isEmpty {
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
                    Button(action: submit) { Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(ComposerRoundButtonStyle(prominent: false)).help("Send into the current answer")
                        .disabled(!reading.isEmpty).composerSlot("composer_steer")
                }
                if isStreaming {
                    Button(action: stop) { Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(ComposerRoundButtonStyle(prominent: true)).help("Stop")
                        .composerSlot("composer_send")
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(ComposerRoundButtonStyle(prominent: true)).disabled(!hasContent || !reading.isEmpty)
                        .composerSlot("composer_send")
                }
            }
            if let commandNotice, noticeDraft == text { Text(commandNotice).font(.callout).textSelection(.enabled) }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).padding(.leading, ComposerMetrics.control + ComposerMetrics.spacing) }
        }.padding(8).glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: AppColor.raised.opacity(AppGlass.surfaceTint))
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14).frame(maxWidth: 768)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                attach(urls); scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            .onAppear(perform: installEditorMonitor).onDisappear { removeEditorMonitor() }
            .onChange(of: text) { _, draft in
                slashMenu.reset()
                if draft != noticeDraft { commandNotice = nil }
            }
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
                            Text(isStreaming ? SteerCopy.placeholder : "Message " + (recipient ?? AppConstants.name) + "…").font(.body).foregroundStyle(.tertiary).lineLimit(1)
                                .allowsHitTesting(false).padding(.top, ComposerMetrics.editorInset).padding(.leading, ComposerMetrics.linePadding)
                        }
                    }
                    .padding(.vertical, ComposerMetrics.textInset - ComposerMetrics.editorInset).focused($focused)
                    .accessibilityLabel("Message")
                    .accessibilityHint(slashMenu.selection(for: text).map { "Selected " + $0.rawValue + ". Use the arrows to choose, then Tab or Return to insert." } ?? "Type / to list chat commands.")
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if let first = suggestions.first { text = GroupRouting.complete(text, with: first); return .handled }
                        if reading.isEmpty { submit() }; return .handled
                    }
                    .onKeyPress(.tab) {
                        guard let first = suggestions.first else { return .ignored }
                        text = GroupRouting.complete(text, with: first)
                        return .handled
                    }
            }
    }

    private func insert(_ command: SlashCommand.Name) {
        commandNotice = nil
        text = command.insertion
        focused = true
    }

    private func submit() {
        if let choice = slashMenu.selection(for: text) { insert(choice); return }
        commandNotice = nil
        switch ComposerSubmission(draft: text, hasAttachments: !attachments.isEmpty) {
        case .message: send()
        case .edit(let draft, let hint):
            slashMenu.reset()
            text = draft
            commandNotice = hint
            focused = true
        case .notice(let notice): commandNotice = notice
        case .goal(let command):
            commandNotice = goalCommand(command)
            if commandNotice == nil || command == .status { text = "" }
        }
        noticeDraft = text
    }

    /// The window that asked (the setup wizard) is still closing, and a field only takes the keyboard in the key
    /// window, so the request is answered a moment later.
    private func takeFocus() {
        guard wantsFocus else { return }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); focused = true; tookFocus() }
    }

    /// Intercept menu keys before NSTextView uses them for caret movement, tabbing
    /// or newline insertion. Text paste and input-method composition stay in the editor.
    private func installEditorMonitor() {
        guard editorMonitor == nil else { return }
        editorMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused, event.window?.isKeyWindow == true, let editor = event.window?.firstResponder as? NSTextView,
                  !editor.hasMarkedText() else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty, let choice = slashMenu.selection(for: text) {
                switch event.keyCode {
                case 125, 126: // Down, Up
                    _ = slashMenu.move(event.keyCode == 125 ? 1 : -1, draft: text)
                    if let selected = slashMenu.selection(for: text) {
                        NSAccessibility.post(element: editor, notification: .announcementRequested,
                                             userInfo: [.announcement: selected.rawValue + " " + selected.usage,
                                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                    }
                case 36, 76, 48: // Return, keypad Enter, Tab
                    if !event.isARepeat { insert(choice) }
                case 53: slashMenu.dismiss(text)
                default: return event
                }
                return nil
            }
            guard modifiers == .command, event.charactersIgnoringModifiers == "v",
                  let item = PasteboardAttachments.item() else { return event }
            switch item {
            case .files(let urls): attach(urls)
            case .image(let data, let name): pasteImage(data, name)
            }
            return nil
        }
    }
    private func removeEditorMonitor() { if let editorMonitor { NSEvent.removeMonitor(editorMonitor) }; editorMonitor = nil }
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
