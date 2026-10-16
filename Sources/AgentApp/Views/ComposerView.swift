import AppKit
import SwiftUI

/// Text, attachments (paperclip, drag-and-drop on the chat, paste) and Send/Stop. While a turn streams,
/// Send steers it when the server supports `run_steer`; otherwise only Stop is offered.
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
    /// P38 C: deAPI dictation. The chat this composer writes into (nil: no microphone); changing it cancels a recording,
    /// and a transcript is only appended to the draft of the chat it was recorded in.
    var dictationContext: String? = nil
    /// P45 1: the `/` commands this chat runs (empty: no menu, e.g. groups).
    var slashCommands: [SlashCommand] = []
    @ObservedObject var dictation: VoiceDictation = VoiceDictation()
    @State private var importing = false; @State private var pasteMonitor: Any?; @FocusState private var focused: Bool
    @State private var slash = SlashMenuState()
    private var slashMatches: [SlashCommand] { slash.matches(for: text, commands: slashCommands) }
    private var slashOpen: Bool { slash.isOpen(for: text, commands: slashCommands) }
    private var dictationBusy: Bool { dictationContext != nil && dictation.isBusy }
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!attachments.isEmpty && !isStreaming) }
    private var suggestions: [String] {
        guard !mentionNames.isEmpty, let partial = GroupRouting.typedMention(in: text) else { return [] }
        return Array(GroupRouting.suggestions(for: partial, names: mentionNames).prefix(6))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if slashOpen { SlashCommandMenu(commands: slashMatches, selected: min(slash.selected, max(slashMatches.count - 1, 0)), pick: pickSlash) }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { name in
                        Button { text = GroupRouting.complete(text, with: name) } label: { Text("@" + name).font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle()) }
                            .buttonStyle(.plain).background(name == suggestions.first ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
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
            if dictationContext != nil, dictation.isBusy || dictation.errorMessage != nil { DictationStatusRow(dictation: dictation) }
            HStack(alignment: .bottom, spacing: 7) {
                Button { importing = true } label: { Image(systemName: "paperclip").frame(width: 28, height: 28) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Attach PNG, JPEG, GIF, WebP, PDF, RTF, DOC, DOCX and text files")
                if !manageActions.isEmpty { ManageBotsMenu(actions: manageActions, perform: manage) { Image(systemName: "plus").frame(width: 28, height: 28) } }
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).frame(height: 30).padding(.vertical, 2).focused($focused)
                    .overlay(alignment: .topLeading) { if text.isEmpty { Text(isStreaming && canSteer ? SteerCopy.placeholder : "Message " + AppConstants.name + "…").foregroundStyle(.tertiary).allowsHitTesting(false).padding(.top, 5).padding(.leading, 5) } }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if slashOpen, let command = slash.current(in: slashMatches) { pickSlash(command); return .handled }
                        if let first = suggestions.first { text = GroupRouting.complete(text, with: first); return .handled }
                        if (!isStreaming || canSteer) && reading.isEmpty && !dictationBusy { send() }; return .handled
                    }
                    .onKeyPress(.upArrow) { guard slashOpen else { return .ignored }; slash.move(-1, count: slashMatches.count); return .handled }
                    .onKeyPress(.downArrow) { guard slashOpen else { return .ignored }; slash.move(1, count: slashMatches.count); return .handled }
                    .onKeyPress(.escape) { guard slashOpen else { return .ignored }; slash.dismissedAt = text; return .handled }
                    .onKeyPress(.tab) { if slashOpen, let command = slash.current(in: slashMatches) { text = SlashMenu.completion(for: command); return .handled }; guard let first = suggestions.first else { return .ignored }; text = GroupRouting.complete(text, with: first); return .handled }
                if let dictationContext { DictationButton(dictation: dictation, context: dictationContext) { focused = true } }
                if isStreaming && canSteer && hasContent {
                    Button(action: send) { Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.bordered).buttonBorderShape(.circle).help("Add to this answer").disabled(dictationBusy)
                }
                if isStreaming {
                    Button(action: stop) { Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(.primary).help("Stop response")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(.primary).disabled(!hasContent || !reading.isEmpty || dictationBusy)
                }
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).padding(.leading, 35) }
        }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16).stroke(AppColor.separator, lineWidth: 0.5))
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14).frame(maxWidth: 768)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                attach(urls); scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            .onAppear(perform: installPasteMonitor).onDisappear { removePasteMonitor(); dictation.cancel() }
            .onChange(of: dictationContext) { _, _ in dictation.cancel() }
            .onChange(of: text) { _, value in if slash.dismissedAt != nil, slash.dismissedAt != value { slash.dismissedAt = nil }; if SlashMenu.query(in: value) == nil { slash.selected = 0 } }
            .onChange(of: dictation.transcript) { _, transcript in
                guard let transcript, let dictationContext, dictation.transcriptContext == dictationContext else { return }
                text = VoiceDictation.appending(transcript, to: text)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if dictation.state == .recording { dictation.cancel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in dictation.cancel() }
    }

    /// Enter or a click on a row: a command with arguments waits for them; the others run at once.
    private func pickSlash(_ command: SlashCommand) {
        text = SlashMenu.completion(for: command); slash.selected = 0
        if !command.takesArguments, !isStreaming || canSteer || command == .stop { send() }
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

/// P38 C: the composer's microphone: record, then stop to transcribe with deAPI into the draft.
private struct DictationButton: View {
    @ObservedObject var dictation: VoiceDictation
    let context: String; let focus: () -> Void
    var body: some View {
        let recording = dictation.state == .recording
        Button {
            if recording { dictation.finish() } else { focus(); dictation.start(context: context) }
        } label: { Image(systemName: recording ? "stop.circle.fill" : "mic").frame(width: 28, height: 28) }
            .buttonStyle(.plain).foregroundStyle(recording ? Color.red : Color.secondary)
            .disabled(dictation.state == .requestingPermission || dictation.state == .transcribing)
            .help(recording ? "Stop recording and transcribe" : "Dictate a message with deAPI")
            .accessibilityLabel(recording ? "Stop recording and transcribe" : "Dictate a message")
            .accessibilityIdentifier("composer.dictation")
    }
}

/// P38 C: recording time, transcription progress, or what dictation needs (a deAPI key, microphone access).
private struct DictationStatusRow: View {
    @ObservedObject var dictation: VoiceDictation
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        HStack(spacing: 8) {
            if dictation.state == .recording {
                Image(systemName: "record.circle").foregroundStyle(.red)
                Text("Recording \(dictation.elapsedText) · 5 min max").monospacedDigit()
            } else if dictation.isBusy {
                ProgressView().controlSize(.small)
                Text(dictation.state == .transcribing ? "Transcribing with deAPI…" : "Requesting microphone access…")
            } else if let error = dictation.errorMessage {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).lineLimit(2)
            }
            Spacer()
            if dictation.needsConfiguration { Button("Voice settings") { store.settingsPane = .voice; openSettings() } }
            if dictation.needsMicrophonePermission { Button("Open Microphone settings") { ExternalLink.open(ExternalLink.microphoneSettings) } }
            Button(dictation.isBusy ? "Cancel" : "Dismiss") { dictation.cancel() }.buttonStyle(.plain)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
    }
}
