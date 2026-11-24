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
        let source = text ?? message.content
        let visible = SwarmhubBlock.visibleText(source, preservingWhitespace: true)
        let blocks = ChatCardParser.parse(visible, preservingProseWhitespace: true)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                let index = indexes.map { $0.indices.contains(offset) ? $0[offset] : -1 } ?? offset
                switch block {
                case .markdown(let text): ProseBlock(text: text)
                case .code(_, let body): CodeBlock(code: body)
                case .choices(let prompt, let options):
                    let picked = message.metadata["picked.\(index)"]
                    ChoicesCard(prompt: prompt, options: options.map { ChatChoiceOption(label: $0, reply: $0) }, picked: picked,
                                enabled: index >= 0 && picked == nil && actionTarget.map { store.canAnswerChoice(message, target: $0) } == true) { answer in
                        guard let actionTarget else { return }
                        store.performCardAction(target: actionTarget, sourceID: message.id, index: index,
                                                expected: .choices(prompt: prompt, options: options), choice: answer)
                    }
                case .draft(let draft):
                    DraftCardView(message: message, target: actionTarget, index: index, draft: draft).id(draft)
                case .image(let alt, let url):
                    if let video = URL(string: url), ["http", "https"].contains(video.scheme?.lowercased() ?? ""), ChatMediaKind(filename: video.lastPathComponent) == .video {
                        ChatVideo(url: video).frame(maxWidth: 420).frame(height: 208).accessibilityLabel(alt)
                    } else { InlineImage(alt: alt, url: url) }
                }
            }
            // What the reply asked the app for, each as one plain line; the block itself is never drawn.
            ForEach(Array(SwarmhubSummary.lines(in: source).enumerated()), id: \.offset) { _, line in FoldedBlockLine(line: line) }
        }
    }
}

struct ProseBlock: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MarkdownBlockContent(blocks: MarkdownBlockParser.parse(text))
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
}

private struct MarkdownBlockContent: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            markdownText(text).font(.body)
        case .heading(let level, let text):
            markdownText(text).font(headingFont(level)).accessibilityAddTraits(.isHeader)
        case .quote(let children):
            if !children.isEmpty {
                MarkdownBlockContent(blocks: children)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.tint).opacity(0.7).frame(width: 3)
                    }
                    .padding(.leading, 4)
            }
        case .rule:
            Divider().padding(.vertical, 3)
        case .list(let items):
            list(items)
        case .table(let header, let rows):
            table(header: header, rows: rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func list(_ items: [MarkdownListItem]) -> some View {
        let widestNumber = items.reduce(into: [Int: String]()) { numbers, item in
            guard let number = item.number, number.count > (numbers[item.depth]?.count ?? 0) else { return }
            numbers[item.depth] = number
        }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let number = item.number, let widest = widestNumber[item.depth] {
                        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .firstTextBaseline)) {
                            Text(widest + ".").hidden().accessibilityHidden(true)
                            Text(number + ".")
                        }.font(.body.monospacedDigit()).foregroundStyle(.tint).fixedSize()
                    } else {
                        Text(item.depth == 0 ? "•" : "◦").font(.body).foregroundStyle(.tint).accessibilityHidden(true)
                    }
                    markdownText(item.text).font(.body)
                }
                .padding(.leading, CGFloat(min(item.depth, 6)) * 16)
            }
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        let border = RoundedRectangle(cornerRadius: 5)
        return ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(header, isHeader: true, hasNextRow: !rows.isEmpty)
                ForEach(rows.indices, id: \.self) { index in
                    tableRow(rows[index], isHeader: false, hasNextRow: index < rows.count - 1)
                }
            }
            .fixedSize()
            .clipShape(border)
            .overlay { border.strokeBorder(AppColor.separator, lineWidth: 1).allowsHitTesting(false) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableRow(_ cells: [String], isHeader: Bool, hasNextRow: Bool) -> some View {
        GridRow {
            ForEach(cells.indices, id: \.self) { index in
                MarkdownTableCellLayout {
                    markdownText(cells[index]).font(isHeader ? .body.bold() : .body)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(isHeader ? AppColor.raised : Color.clear)
                .overlay(alignment: .trailing) {
                    if index < cells.count - 1 { AppColor.separator.frame(width: 1).allowsHitTesting(false) }
                }
                .overlay(alignment: .bottom) {
                    if hasNextRow { AppColor.separator.frame(height: 1).allowsHitTesting(false) }
                }
                .accessibilityAddTraits(isHeader ? .isHeader : [])
            }
        }
    }

    private func markdownText(_ value: String) -> some View {
        let inline = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(inline ?? AttributedString(value))
            .textSelection(.enabled)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Give wrapped text its final width during the grid's ideal-size pass so it reports the full row height.
private struct MarkdownTableCellLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maximumWidth: CGFloat = 240
        let width = min(proposal.width ?? maximumWidth, maximumWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
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

struct ChoicesCard: View {
    let prompt: String
    let options: [ChatChoiceOption]
    let picked: String?
    let enabled: Bool
    let answer: (ChatChoiceAnswer) -> Void
    @State private var writingOther = false
    @State private var other = ""
    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !prompt.isEmpty { Text(prompt).font(.callout.weight(.semibold)) }
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                optionButton(option.label, selected: picked == option.reply) {
                    if isOther(option) { openOther() } else { answer(.option(option.reply)) }
                }
            }
            if enabled && !options.contains(where: isOther) { optionButton("Other", action: openOther) }
            if enabled && writingOther {
                HStack {
                    TextField("Write your reply", text: $other)
                        .focused($otherFocused).onSubmit(sendOther)
                    Button("Send", action: sendOther).disabled(other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(12).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }

    private func optionButton(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).multilineTextAlignment(.leading)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).accessibilityHidden(true) }
            }
        }.buttonStyle(ChoiceOptionStyle(picked: selected, answered: picked != nil))
            .accessibilityAddTraits(selected ? .isSelected : []).disabled(!enabled)
    }

    private func isOther(_ option: ChatChoiceOption) -> Bool { option.label.caseInsensitiveCompare("Other") == .orderedSame }
    private func openOther() { writingOther = true; otherFocused = true }
    private func sendOther() { answer(.other(other)) }
}

/// Inline review and editing for a draft sent back to its author.
private struct DraftCardView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    let target: ConversationActionTarget?
    let index: Int
    let draft: DraftCard
    @State private var current: DraftCard
    @State private var isEditing = false

    init(message: ChatMessage, target: ConversationActionTarget?, index: Int, draft: DraftCard) {
        self.message = message
        self.target = target
        self.index = index
        self.draft = draft
        _current = State(initialValue: draft)
    }

    private var sentState: String? { message.metadata["draftSent.\(index)"] }
    private var canEdit: Bool { target != nil && index >= 0 && sentState == nil && !message.isStreaming }
    private var editing: Bool { isEditing && canEdit }
    private var title: String {
        if current.isEmail { return "Review email" }
        if let channel = current.channel { return "Review \(channel)" }
        return "Review message"
    }
    private var channelDetail: String? {
        guard let channel = current.channel, current.isEmail, channel.caseInsensitiveCompare("Email") != .orderedSame else { return nil }
        return channel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: current.isEmail ? "envelope" : "bubble.left.and.text.bubble.right")
                    .font(.callout.weight(.semibold))
                Spacer()
                if canEdit {
                    if current != draft {
                        Button("Reset") { current = draft }.buttonStyle(.link)
                    }
                    Button(isEditing ? "Done editing" : "Edit") { isEditing.toggle() }
                }
            }.padding(12)
            if editing || current.to != nil || current.subject != nil || channelDetail != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let channelDetail { LabeledContent("Channel") { Text(channelDetail) } }
                    if editing {
                        LabeledContent("To") { TextField("To", text: field(\.to)).labelsHidden() }
                        if current.isEmail {
                            LabeledContent("Subject") { TextField("Subject", text: field(\.subject)).labelsHidden() }
                        }
                    } else {
                        if let to = current.to { LabeledContent("To") { Text(to) } }
                        if let subject = current.subject { LabeledContent("Subject") { Text(subject).fontWeight(.medium) } }
                    }
                }.font(.caption).padding(12)
            }
            Divider()
            if editing {
                TextEditor(text: $current.body)
                    .accessibilityLabel("Body")
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 140)
                    .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            } else {
                Text(verbatim: current.body).font(.callout).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(12)
            }
            Divider()
            HStack {
                if let sentState {
                    let status = sentState == "edited" ? "Sent edited draft" : message.metadata["draftSimulation.\(index)"] ?? "Sent “Send it”"
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { copyToPasteboard(draftText) }
                Button("Send", action: send)
                    .buttonStyle(NeutralPrimaryButtonStyle()).disabled(!canEdit || target.map(store.isStreaming(for:)) == true)
            }.padding(10)
        }.frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }

    private func field(_ keyPath: WritableKeyPath<DraftCard, String?>) -> Binding<String> {
        Binding(
            get: { current[keyPath: keyPath] ?? "" },
            set: { current[keyPath: keyPath] = $0.isEmpty && draft[keyPath: keyPath] == nil ? nil : $0 }
        )
    }

    private var draftText: String {
        let headers = [current.channel.map { "Channel: \($0)" }, current.to.map { "To: \($0)" }, current.subject.map { "Subject: \($0)" }]
        return (headers.compactMap { $0 } + [current.body]).joined(separator: "\n")
    }

    private func send() {
        guard let target else { return }
        if store.performCardAction(target: target, sourceID: message.id, index: index, expected: .draft(draft),
                                   editedDraft: current == draft ? nil : current) {
            isEditing = false
        }
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
