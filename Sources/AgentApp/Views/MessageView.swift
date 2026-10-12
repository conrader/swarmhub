import SwiftUI

struct MessageView: View {
    @ObservedObject var message: ChatMessage
    let repliedMessage: ChatMessage?; let reply: () -> Void
    @State private var showingReactions = false
    init(message: ChatMessage, repliedMessage: ChatMessage? = nil, reply: @escaping () -> Void = {}) { self.message = message; self.repliedMessage = repliedMessage; self.reply = reply }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 110) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
                if let repliedMessage { HStack(spacing: 5) { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2, height: 24); Text(repliedMessage.content).lineLimit(1) }.font(.caption).foregroundStyle(.secondary) }
                content
                if !message.reactions.isEmpty { HStack(spacing: 3) { ForEach(message.reactions, id: \.self) { Text($0).font(.caption).padding(4).background(.background, in: Capsule()).overlay(Capsule().stroke(.primary.opacity(0.1))) } } }
                HStack(spacing: 10) { Button { showingReactions.toggle() } label: { Image(systemName: "face.smiling") }; Button(action: reply) { Image(systemName: "arrowshape.turn.up.left") } }.buttonStyle(.plain).foregroundStyle(.tertiary).font(.caption).opacity(message.role == .system ? 0 : 1)
                    .popover(isPresented: $showingReactions) { HStack { ForEach(["👍", "❤️", "😂", "‼️", "?"], id: \.self) { emoji in Button(emoji) { if !message.reactions.contains(emoji) { message.reactions.append(emoji) }; showingReactions = false }.buttonStyle(.plain) } }.padding(10) }
            }
            if message.role != .user { Spacer(minLength: 80) }
        }.padding(.horizontal, 28).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        switch message.presentation {
        case .draftEmail: DraftEmailCard(message: message)
        case .options: OptionCard(message: message)
        case .attachment: AttachmentCard(message: message)
        case .image: ImageCard(message: message)
        case .links: LinkPills(message: message)
        case .voiceMemo: VoiceMemoCard(message: message)
        case .text:
            if message.role == .system {
                Label(message.content, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else if message.role == .user {
                Text(markdown).textSelection(.enabled).font(.body).lineSpacing(3).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                MarkdownContent(text: message.content)
                if message.isStreaming { ProgressView().controlSize(.mini) }
            }
        }
    }
    private var markdown: AttributedString { (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .full))) ?? AttributedString(message.content) }
}

private struct VoiceMemoCard: View { let message: ChatMessage; @State private var playing = false; var body: some View { HStack(spacing: 12) { Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 28, height: 28).background(.primary, in: Circle()).foregroundStyle(.background) }.buttonStyle(.plain); HStack(spacing: 3) { ForEach(0..<18, id: \.self) { index in Capsule().fill(.secondary.opacity(0.55)).frame(width: 2, height: CGFloat(5 + (index * 7) % 17)) } }; Text(message.metadata["duration"] ?? "0:00").font(.caption).foregroundStyle(.secondary) }.padding(10).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16)) } }
private struct LinkPills: View { let message: ChatMessage; var body: some View { HStack { ForEach((message.metadata["links"] ?? "").components(separatedBy: "|"), id: \.self) { label in Button { } label: { Label(label, systemImage: "link").font(.caption) }.buttonStyle(.bordered) } } } }
private struct ImageCard: View { let message: ChatMessage; var body: some View { RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.06)).frame(width: 320, height: 190).overlay(VStack { Image(systemName: "photo").font(.largeTitle); Text(message.metadata["name"] ?? "Image").font(.caption) }.foregroundStyle(.secondary)) } }

private struct MarkdownContent: View {
    let text: String
    private var chunks: [(String, Bool)] {
        let pieces = text.components(separatedBy: "```")
        return pieces.enumerated().map { index, value in
            var value = value; if index % 2 == 1, let newline = value.firstIndex(of: "\n") { value = String(value[value.index(after: newline)...]) }
            return (value, index % 2 == 1)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                if chunk.1 {
                    ScrollView(.horizontal) { Text(chunk.0.trimmingCharacters(in: .newlines)).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10)).overlay(alignment: .topTrailing) { Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.tertiary).padding(9) }
                } else if !chunk.0.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(chunk.0.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            markdownParagraph(paragraph)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private func markdownParagraph(_ paragraph: String) -> some View {
        if paragraph.hasPrefix("## ") {
            Text(String(paragraph.dropFirst(3))).font(.title3.weight(.semibold))
        } else if paragraph.hasPrefix("- ") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(paragraph.components(separatedBy: "\n"), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(Color.accentColor); Text(inlineMarkdown(String(line.dropFirst(2)))).fixedSize(horizontal: false, vertical: true) }
                }
            }
        } else {
            Text(inlineMarkdown(paragraph)).textSelection(.enabled).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func inlineMarkdown(_ value: String) -> AttributedString { (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value) }
}

private struct DraftEmailCard: View {
    let message: ChatMessage; @State private var sent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sent ? "Email sent" : "Email draft").font(.callout.weight(.semibold)).padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("To") { Text(message.metadata["to"] ?? "") }; LabeledContent("Subject") { Text(message.metadata["subject"] ?? "").fontWeight(.medium) }
                Divider(); Text(message.metadata["body"] ?? "").font(.caption).lineSpacing(2).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }.font(.caption).padding(12)
            Divider(); HStack { Spacer(); Button(sent ? "Sent" : "Send") { sent = true }.buttonStyle(NeutralPrimaryButtonStyle()).disabled(sent) }.padding(10)
        }.frame(maxWidth: 500).background(.background, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(.primary.opacity(0.14), lineWidth: 0.5))
    }
}

private struct OptionCard: View {
    let message: ChatMessage; @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(message.content).font(.callout.weight(.semibold)); FlowButtons(options: (message.metadata["options"] ?? "").components(separatedBy: "|"), selected: $selected)
        }.padding(14).frame(maxWidth: 500, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(.primary.opacity(0.14), lineWidth: 0.5))
    }
}

private struct FlowButtons: View {
    let options: [String]; @Binding var selected: String?
    var body: some View {
        HStack {
            ForEach(options, id: \.self) { option in
                Button(option) { selected = option }
                    .buttonStyle(.bordered)
                    .tint(selected == option ? .primary : .secondary)
            }
        }
    }
}

private struct AttachmentCard: View {
    let message: ChatMessage
    var body: some View { HStack { Image(systemName: "doc").font(.title2).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(message.metadata["name"] ?? "Attachment").fontWeight(.medium); Text(message.metadata["size"] ?? "File").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.down.circle") }.padding(12).frame(maxWidth: 380).background(.background, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(.primary.opacity(0.14), lineWidth: 0.5)) }
}
