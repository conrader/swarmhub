import SwiftUI

struct MessageView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 110) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
                content
                HStack(spacing: 5) {
                    ForEach(message.reactions, id: \.self) { emoji in Text(emoji).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.background, in: Capsule()).overlay(Capsule().stroke(.quaternary)) }
                    if hovering { reactionMenu.transition(.opacity.combined(with: .scale)) }
                }
            }
            if message.role != .user { Spacer(minLength: 80) }
        }.padding(.horizontal, 28).padding(.vertical, 8).onHover { hovering = $0 }
    }

    @ViewBuilder private var content: some View {
        switch message.presentation {
        case .draftEmail: DraftEmailCard(message: message)
        case .options: OptionCard(message: message)
        case .attachment: AttachmentCard(message: message)
        case .text:
            if message.role == .system {
                Label(message.content, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else if message.role == .user {
                Text(markdown).textSelection(.enabled).font(.body).lineSpacing(3).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            } else {
                MarkdownContent(text: message.content)
                if message.isStreaming { ProgressView().controlSize(.mini) }
            }
        }
    }
    private var reactionMenu: some View {
        Menu { ForEach(["👍", "❤️", "✨", "😂"], id: \.self) { emoji in Button(emoji) { store.addReaction(emoji, to: message) } } } label: {
            Image(systemName: "face.smiling").font(.caption).foregroundStyle(.secondary).frame(width: 25, height: 22).background(.quaternary.opacity(0.7), in: Capsule())
        }.menuStyle(.borderlessButton).fixedSize()
    }
    private var markdown: AttributedString { (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .full))) ?? AttributedString(message.content) }
}

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
    let message: ChatMessage; @State private var sent = false; @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(sent ? "Email sent" : "Email draft", systemImage: sent ? "checkmark.circle.fill" : "envelope").font(.callout.weight(.semibold)).padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("To") { Text(message.metadata["to"] ?? "") }; LabeledContent("Subject") { Text(message.metadata["subject"] ?? "").fontWeight(.medium) }
                Divider(); Text(message.metadata["body"] ?? "").font(.caption).lineSpacing(2).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }.font(.caption).padding(12)
            Divider(); HStack { Button("Edit", systemImage: "pencil") { editing.toggle() }; Spacer(); Button { sent = true } label: { Label(sent ? "Sent" : "Send", systemImage: sent ? "checkmark" : "paperplane.fill").foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 5).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).disabled(sent) }.padding(10)
        }.frame(maxWidth: 500).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary)).shadow(color: .black.opacity(0.04), radius: 10, y: 3)
        .alert("Edit draft", isPresented: $editing) { Button("Done") {} } message: { Text("Draft editing is represented by this prototype action.") }
    }
}

private struct OptionCard: View {
    let message: ChatMessage; @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(message.content).font(.callout.weight(.semibold)); FlowButtons(options: (message.metadata["options"] ?? "").components(separatedBy: "|"), selected: $selected)
        }.padding(14).frame(maxWidth: 500, alignment: .leading).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.18)))
    }
}

private struct FlowButtons: View {
    let options: [String]; @Binding var selected: String?
    var body: some View {
        HStack {
            ForEach(options, id: \.self) { option in
                Button(option) { selected = option }
                    .buttonStyle(.bordered)
                    .tint(selected == option ? Color.accentColor : .secondary)
            }
        }
    }
}

private struct AttachmentCard: View {
    let message: ChatMessage
    var body: some View { HStack { Image(systemName: "doc.fill").font(.title2).foregroundStyle(Color.accentColor); VStack(alignment: .leading) { Text(message.metadata["name"] ?? "Attachment").fontWeight(.medium); Text(message.metadata["size"] ?? "File").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.down.circle") }.padding(12).frame(maxWidth: 380).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)) }
}
