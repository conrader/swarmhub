import AppKit
import SwiftUI

/// Text, attachments (paperclip, drag-and-drop on the chat, paste) and Send/Stop. While a turn streams,
/// Send steers it when the server supports `run_steer`; otherwise only Stop is offered.
struct ComposerView: View {
    @Binding var text: String; @Binding var attachments: [ChatAttachment]
    let isStreaming: Bool; var canSteer = false
    let send: () -> Void; let stop: () -> Void
    var attach: ([URL]) -> Void = { _ in }; var pasteImage: (Data, String) -> Void = { _, _ in }
    @State private var importing = false; @State private var pasteMonitor: Any?; @FocusState private var focused: Bool
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!attachments.isEmpty && !isStreaming) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack(spacing: 6) { ForEach(attachments) { attachment in AttachmentTile(attachment: attachment, size: 64) { attachments.removeAll { $0.id == attachment.id } } } } }
            }
            HStack(alignment: .bottom, spacing: 7) {
                Button { importing = true } label: { Image(systemName: "paperclip").frame(width: 28, height: 28) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Attach images or text files")
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).frame(height: 30).padding(.vertical, 2).focused($focused)
                    .overlay(alignment: .topLeading) { if text.isEmpty { Text(isStreaming && canSteer ? "Steer the running reply…" : "Message " + AppConstants.name + "…").foregroundStyle(.tertiary).allowsHitTesting(false).padding(.top, 5).padding(.leading, 5) } }
                    .onKeyPress(.return, phases: .down) { press in if press.modifiers.contains(.shift) { return .ignored }; if !isStreaming || canSteer { send() }; return .handled }
                if isStreaming && canSteer && hasContent {
                    Button(action: send) { Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.bordered).buttonBorderShape(.circle).help("Steer the running reply")
                }
                if isStreaming {
                    Button(action: stop) { Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(.primary).help("Stop response")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(.primary).disabled(!hasContent)
                }
            }
        }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16).stroke(AppColor.separator, lineWidth: 0.5))
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14).frame(maxWidth: 768)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                attach(urls); scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            }
            .onAppear(perform: installPasteMonitor).onDisappear(perform: removePasteMonitor)
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
