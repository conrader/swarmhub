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
    var renderedBlocks: [TranscriptText.Block]? = nil
    var body: some View {
        let shownContent = message.content
        let source = text ?? shownContent
        let blocks = renderedBlocks ?? TranscriptText(reply: source, segments: nil).parts[0]
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, rendered in
                let block = rendered.card
                let index = indexes.map { $0.indices.contains(offset) ? $0[offset] : -1 } ?? offset
                switch block {
                case .markdown(let text): ProseBlock(text: text, rendered: rendered.prose)
                case .code(_, let body):
                    if let run = rendered.run { CodeBlock(code: body, run: run) }
                case .choices(let prompt, let options):
                    let key = "picked.\(index)"
                    let status = actionTarget.map { store.choiceStatus(message, target: $0, key: key, binary: ChoiceReply.isYesNo(options)) }
                    ChoicesCard(prompt: prompt, promptRun: rendered.run, options: options.map { ChatChoiceOption(label: $0, reply: $0) }, picked: status?.picked ?? message.metadata[key],
                                enabled: index >= 0 && status?.enabled == true) { answer in
                        guard let actionTarget else { return }
                        store.performCardAction(target: actionTarget, sourceID: message.id, index: index,
                                                expected: block, choice: answer, shownContent: shownContent)
                    }
                case .multiChoices(let prompt, let options):
                    MultipleChoiceCard(prompt: prompt, promptRun: rendered.run, options: options, picked: message.metadata["picked.\(index)"],
                        enabled: index >= 0 && actionTarget.map { store.choiceStatus(message, target: $0, key: "picked.\(index)", binary: false).enabled } == true) { answer in
                        guard let actionTarget else { return }
                        store.performCardAction(target: actionTarget, sourceID: message.id, index: index, expected: block, choice: answer, shownContent: shownContent)
                    }.id(options)
                case .pageDraft(let draft):
                    let key = "pageReview.\(index)"
                    let status = actionTarget.map { store.choiceStatus(message, target: $0, key: key, binary: false) }
                    PageDraftCard(draft: draft, title: rendered.run, prose: rendered.prose, picked: status?.picked ?? message.metadata[key],
                                  enabled: index >= 0 && !message.isStreaming && status?.enabled == true) { decision in
                        guard let actionTarget else { return }
                        store.performCardAction(target: actionTarget, sourceID: message.id, index: index,
                                                expected: block, pageDecision: decision, shownContent: shownContent)
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
    var rendered: [TranscriptText.Prose]? = nil
    private var blocks: [TranscriptText.Prose] {
        if let rendered { return rendered }
        var projection = TranscriptText()
        return projection.prose(text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MarkdownBlockContent(blocks: blocks)
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

/// User Markdown shares the same text coordinates, without activating assistant cards.
struct UserMessageText: View {
    @Environment(\.transcriptRow) private var row
    @Environment(\.transcriptSelection) private var selection
    let source: String
    var body: some View {
        let projection = TranscriptText(user: source)
        let _ = selection?.rendered(row, text: projection.string)
        let blocks = projection.parts[0]
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                if let run = block.run {
                    TranscriptRunView(run: run, style: .code).font(.system(.callout, design: .monospaced))
                } else {
                    MarkdownBlockContent(blocks: block.prose)
                }
            }
        }
    }
}

private struct MarkdownBlockContent: View {
    let blocks: [TranscriptText.Prose]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
    }

    @ViewBuilder private func blockView(_ block: TranscriptText.Prose) -> some View {
        switch block {
        case .paragraph(let text):
            markdownText(text).font(.body)
        case .heading(let level, let text):
            markdownText(text, style: .heading(level)).font(headingFont(level)).accessibilityAddTraits(.isHeader)
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
        case .table(let rows):
            table(rows)
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

    private func list(_ items: [(depth: Int, marker: TranscriptText.Run, text: TranscriptText.Run)]) -> some View {
        let widths = Dictionary(grouping: items, by: \.depth).mapValues { items in
            items.map { String($0.marker.value.characters) }.max { $0.count < $1.count } ?? ""
        }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .top, spacing: 8) {
                    ZStack(alignment: .trailing) {
                        Text(widths[item.depth] ?? "").hidden().accessibilityHidden(true)
                        TranscriptRunView(run: item.marker, style: .marker)
                            .accessibilityHidden(item.marker.value.characters.first?.isNumber != true)
                    }.font(.body.monospacedDigit()).foregroundStyle(.tint).fixedSize()
                    markdownText(item.text).font(.body)
                }
                .padding(.leading, CGFloat(min(item.depth, 6)) * 16)
            }
        }
    }

    private func table(_ rows: [[TranscriptText.Run]]) -> some View {
        let border = RoundedRectangle(cornerRadius: 5)
        return ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    tableRow(rows[index], isHeader: index == 0, hasNextRow: index < rows.count - 1)
                }
            }
            .fixedSize()
            .clipShape(border)
            .overlay { border.strokeBorder(AppColor.separator, lineWidth: 1).allowsHitTesting(false) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableRow(_ cells: [TranscriptText.Run], isHeader: Bool, hasNextRow: Bool) -> some View {
        GridRow {
            ForEach(cells.indices, id: \.self) { index in
                MarkdownTableCellLayout {
                    markdownText(cells[index], style: isHeader ? .bold : .body).font(isHeader ? .body.bold() : .body)
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

    private func markdownText(_ run: TranscriptText.Run, style: TranscriptFont = .body) -> some View {
        TranscriptRunView(run: run, style: style)
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
    let run: TranscriptText.Run
    var body: some View {
        ScrollView(.horizontal) { TranscriptRunView(run: run, style: .code).font(.system(.callout, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
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

private struct MultipleChoiceCard: View {
    let prompt: String
    var promptRun: TranscriptText.Run? = nil
    let options: [String]
    let picked: String?
    let enabled: Bool
    let answer: (ChatChoiceAnswer) -> Void
    @State private var selected: Set<String> = []
    @State private var other = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let promptRun {
                TranscriptRunView(run: promptRun, style: .bold).font(.callout.weight(.semibold))
            } else if !prompt.isEmpty { Text(prompt).font(.callout.weight(.semibold)) }
            if let picked {
                Label(picked, systemImage: "checkmark")
            } else {
                ForEach(options, id: \.self) { option in
                    Toggle(option, isOn: Binding(get: { selected.contains(option) }, set: { checked in
                        if checked { selected.insert(option) } else { selected.remove(option) }
                    })).toggleStyle(.checkbox)
                }
                TextField("Add your own answer (optional)", text: $other)
                Button("Send") { answer(.multiple(selected, other: other)) }
                    .disabled(selected.isEmpty && other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.disabled(!enabled && picked == nil).appleCard(padding: 12)
    }
}

struct ChoicesCard: View {
    let prompt: String
    var promptRun: TranscriptText.Run? = nil
    let options: [ChatChoiceOption]
    let picked: String?
    let enabled: Bool
    let answer: (ChatChoiceAnswer) -> Void
    @State private var writingOther = false
    @State private var other = ""
    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let promptRun {
                TranscriptRunView(run: promptRun, style: .bold).font(.callout.weight(.semibold))
            } else if !prompt.isEmpty { Text(prompt).font(.callout.weight(.semibold)) }
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                optionButton(option.label, selected: picked == option.reply) {
                    if isOther(option) { openOther() } else { answer(.option(option.reply)) }
                }
            }
            if let picked, !options.contains(where: { $0.reply == picked }) {
                Label(picked, systemImage: "checkmark")
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
private struct PageDraftCard: View {
    let draft: PageDraft
    let title: TranscriptText.Run?
    let prose: [TranscriptText.Prose]
    let picked: String?
    let enabled: Bool
    let decide: (PageDraft.Decision) -> Void

    @AppStorage("accent") private var accent = AppTheme.defaultAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let title {
                        TranscriptRunView(run: title, style: .heading(3)).font(.headline).accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 4)
                    Text("Draft · Page").font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
                }
                ProseBlock(text: draft.markdown, rendered: prose)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(AppColor.separator) }

            Group {
                if let picked {
                    let approved = picked == PageDraft.Decision.approve.rawValue || picked == PageDraft.Decision.approve.reply
                    Label(approved ? "Draft approved" : "Shorter draft requested", systemImage: approved ? "checkmark.circle" : "arrow.uturn.backward")
                        .font(.callout)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { prompt; Spacer(minLength: 8); actions }
                        VStack(alignment: .leading, spacing: 8) { prompt; actions }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.raised)
            .overlay(alignment: .leading) { Rectangle().fill(AppTheme.accentColor(for: accent)).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(AppColor.separator) }
        }.frame(maxWidth: 500, alignment: .leading)
    }

    private var prompt: some View {
        Text("Approve this draft?").font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack {
            Button("Make shorter") { decide(.shorten) }
            Button("Approve") { decide(.approve) }.buttonStyle(NeutralPrimaryButtonStyle())
        }
        .fixedSize().disabled(!enabled)
    }
}

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
