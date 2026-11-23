import AppKit
import SwiftUI

/// Assistant Markdown with inline cards: choices, drafts, link pills and images (see `ChatCardParser`); swarmhub blocks read
/// as one folded line each (P51).
struct MarkdownContent: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    /// Where the cards answer; nil (renders) shows them without actions.
    var actionTarget: ConversationActionTarget? = nil
    /// One text segment of an ordered reply (nil = the whole text), and for each of its blocks the place that block
    /// has in the whole reply (`ReplyLayout.blockIndexes`), which is what a card's answer is stored and checked by.
    var text: String? = nil; var indexes: [Int]? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatCardParser.parse(SwarmhubBlock.visibleText(text ?? message.content)).enumerated()), id: \.offset) { offset, block in
                let index = indexes.map { $0.indices.contains(offset) ? $0[offset] : -1 } ?? offset
                switch block {
                case .markdown(let text): ProseBlock(text: text)
                case .code(_, let body): CodeBlock(code: body)
                case .choices(let prompt, let options): ChoicesCard(message: message, target: actionTarget, index: index, prompt: prompt, options: options)
                case .draft(let draft): DraftCardView(message: message, target: actionTarget, index: index, draft: draft)
                case .image(let alt, let url):
                    if let video = URL(string: url), ["http", "https"].contains(video.scheme?.lowercased() ?? ""), ChatMediaKind(filename: video.lastPathComponent) == .video {
                        ChatVideo(url: video).frame(maxWidth: 420).frame(height: 208).accessibilityLabel(alt)
                    } else { InlineImage(alt: alt, url: url) }
                }
            }
            // What the reply asked the app for, each as one plain line; the block itself is never drawn.
            ForEach(Array(SwarmhubSummary.lines(in: text ?? message.content).enumerated()), id: \.offset) { _, line in FoldedBlockLine(line: line) }
        }
    }
}

struct ProseBlock: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in markdownParagraph(paragraph) }
            let urls = ChatCardParser.bareURLs(in: text)
            if !urls.isEmpty { LinkPillRow(urls: urls) }
            ForEach(ChatCardParser.links(in: text), id: \.self) { link in
                if let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    switch ChatMediaKind(filename: url.lastPathComponent) {
                    case .image: InlineImage(alt: url.lastPathComponent, url: link)
                    case .video: ChatVideo(url: url).frame(maxWidth: 420).frame(height: 208).accessibilityLabel(url.lastPathComponent)
                    case nil: EmptyView()
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.tint); Text(inlineMarkdown(String(line.dropFirst(2)))).fixedSize(horizontal: false, vertical: true) }
                }
            }
        } else {
            Text(inlineMarkdown(paragraph)).textSelection(.enabled).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func inlineMarkdown(_ value: String) -> AttributedString { (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value) }
}

private struct CodeBlock: View {
    let code: String
    var body: some View {
        ScrollView(.horizontal) { Text(code.trimmingCharacters(in: .newlines)).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { Button { copyToPasteboard(code) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary).padding(9).help("Copy") }
    }
}

struct LinkPillRow: View {
    let urls: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(urls, id: \.self) { url in
                Button { if let target = URL(string: url) { ExternalLink.open(target) } } label: { Label(ChatCardParser.pillLabel(url), systemImage: "link").font(.caption).lineLimit(1) }
                    .buttonStyle(.bordered).help(url)
            }
        }
    }
}

/// Picking an option sends it as the user's reply to the card's own chat (P38: to its author in a group); the pick is
/// remembered on the message.
private struct ChoicesCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage; let target: ConversationActionTarget?; let index: Int; let prompt: String; let options: [String]
    private var picked: String? { message.metadata["picked.\(index)"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !prompt.isEmpty { Text(prompt).font(.callout.weight(.semibold)) }
            ForEach(options, id: \.self) { option in
                Button { pick(option) } label: {
                    HStack { Text(option).multilineTextAlignment(.leading); Spacer(); if picked == option { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).accessibilityHidden(true) } }
                }.buttonStyle(ChoiceOptionStyle(picked: picked == option, answered: picked != nil))
                    .accessibilityAddTraits(picked == option ? .isSelected : []).disabled(target == nil || picked != nil || message.isStreaming || target.map(store.isStreaming(for:)) == true)
            }
        }.padding(12).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }
    private func pick(_ option: String) {
        guard let target, picked == nil, !store.isStreaming(for: target) else { return }
        store.performCardAction(target: target, sourceID: message.id, index: index, expected: .choices(prompt: prompt, options: options), choice: option)
    }
}

/// Draft card: "Send" posts "Send it" to the bot that wrote it (P38: in the card's own chat), "Copy" copies the draft text.
private struct DraftCardView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage; let target: ConversationActionTarget?; let index: Int; let draft: DraftCard
    private var sent: Bool { message.metadata["draftSent.\(index)"] != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Draft").font(.callout.weight(.semibold)).padding(12)
            if draft.to != nil || draft.subject != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let to = draft.to { LabeledContent("To") { Text(to) } }
                    if let subject = draft.subject { LabeledContent("Subject") { Text(subject).fontWeight(.medium) } }
                }.font(.caption).padding(12)
            }
            Divider()
            Text(draft.body).font(.callout).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(12)
            Divider()
            HStack {
                if sent { Text(message.metadata["draftSimulation.\(index)"] ?? "Sent “Send it”").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy") { copyToPasteboard(draftText) }
                Button("Send") { if let target { store.performCardAction(target: target, sourceID: message.id, index: index, expected: .draft(draft)) } }
                    .buttonStyle(NeutralPrimaryButtonStyle()).disabled(target == nil || sent || message.isStreaming || target.map(store.isStreaming(for:)) == true)
            }.padding(10)
        }.frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }
    private var draftText: String {
        ([draft.to.map { "To: \($0)" }, draft.subject.map { "Subject: \($0)" }].compactMap { $0 } + [draft.body]).joined(separator: "\n")
    }
}

private struct InlineImage: View {
    let alt: String; let url: String; @State private var previewing = false
    var body: some View {
        Button { previewing = true } label: { RemoteOrDataImage(url: url, maxWidth: 360, maxHeight: 280) }.buttonStyle(.plain).help(alt.isEmpty ? "Image" : alt)
            .sheet(isPresented: $previewing) { ImagePreviewSheet(title: alt.isEmpty ? "Image" : alt) { RemoteOrDataImage(url: url, maxWidth: 1000, maxHeight: 760) } }
    }
}

/// http(s) images load asynchronously; `data:image/...` URLs are decoded locally.
struct RemoteOrDataImage: View {
    let url: String; let maxWidth: CGFloat; let maxHeight: CGFloat
    var body: some View {
        Group {
            if url.lowercased().hasPrefix("data:") {
                if let image = Self.decode(url) { Image(nsImage: image).resizable().scaledToFit() } else { placeholder }
            } else {
                AsyncImage(url: URL(string: url)) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { placeholder }
                }
            }
        }.frame(maxWidth: maxWidth, maxHeight: maxHeight).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var placeholder: some View { RoundedRectangle(cornerRadius: 10).fill(AppColor.raised).frame(width: 220, height: 140).overlay(Image(systemName: "photo").foregroundStyle(.secondary)) }
    static func decode(_ dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

func copyToPasteboard(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }

/// One option of a question a bot asks in its reply. The one that was picked is filled with the accent and ticked,
/// and stays at full strength when the card can no longer be answered; the others step back. (The picked one was
/// drawn a shade lighter than the rest and dimmed with them, so it could not be told which had been chosen.)
struct ChoiceOptionStyle: ButtonStyle {
    let picked: Bool
    /// One of the options was picked already.
    let answered: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .foregroundStyle(picked ? AnyShapeStyle(AppColor.onAccent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 11).padding(.vertical, 7).contentShape(Rectangle())
            .background(picked ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(AppColor.raised), in: shape)
            .overlay { if !picked { shape.strokeBorder(AppColor.outline, lineWidth: 1) } }
            .overlay { if configuration.isPressed { shape.fill(Color.primary.opacity(0.08)) } }
            .opacity(picked ? 1 : answered ? 0.5 : isEnabled ? 1 : 0.7)
    }
}
