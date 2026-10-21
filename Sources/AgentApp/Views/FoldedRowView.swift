import SwiftUI

/// P51: which folded rows (and parts of them) are open. Memory only and per row: every launch starts folded.
@MainActor final class TechnicalFolds: ObservableObject {
    @Published private(set) var open: Set<String> = []
    func isOpen(_ key: String) -> Bool { open.contains(key) }
    func toggle(_ key: String) { if open.remove(key) == nil { open.insert(key) } }
    func unfold(_ key: String) { open.insert(key) }
    /// A row ("<id>"), its "Show all" ("<id>#all"), or one ```swarmhub fence of a reply ("<id>#fence<n>").
    nonisolated static func key(_ id: UUID, _ part: String? = nil) -> String { id.uuidString + (part.map { "#" + $0 } ?? "") }
}

/// P51: a technical row as one secondary line with a disclosure chevron; unfolded, the original below it. Copy copies the
/// line, Copy original the raw text.
struct FoldedRowView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var folds: TechnicalFolds
    @ObservedObject var message: ChatMessage
    let fold: TechnicalFold
    /// An app request's result row.
    var partner: ChatMessage?

    var body: some View {
        let key = TechnicalFolds.key(message.id), open = folds.isOpen(key)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                FoldButton(open: open, summary: fold.summary) { folds.toggle(key) } icon: { icon }
                if let thread = threadKey {
                    Text("·").foregroundStyle(.tertiary)
                    Button(BotMessageCopy.openThread) { store.openThread(thread) }.buttonStyle(.link)
                }
                Text(message.createdAt, style: .time).foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary)
            if open { detail }
        }
        .contextMenu {
            Button("Copy") { copyToPasteboard(fold.summary) }
            Button("Copy original") { copyToPasteboard(fold.original) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch fold.kind {
        case .appRequest, .appResult: Image(systemName: "square.grid.2x2")
        case .skill: Image(systemName: "book.closed")
        case .botMessage, .botReply: BotMark(profile: fold.profile ?? "", size: 16, isWorking: message.isStreaming)
        case .outOfBand: Image(systemName: "arrow.turn.down.right")
        case .routineOutput: Image(systemName: "alarm")
        case .ack: Image(systemName: "checkmark.circle")
        case .internalNote: Image(systemName: "gearshape.2")
        }
    }

    /// P42's Open conversation: from the exchange card's metadata, or a header row in the open bot's chat.
    private var threadKey: BotThreadKey? {
        guard let from = fold.profile else { return nil }
        if let to = message.metadata[BotMessageKey.to] { return BotThreadKey(from: from, to: to, session: message.metadata[BotMessageKey.session]) }
        return store.selectedBot?.hermesProfile.map { BotThreadKey(from: from, to: $0) }
    }

    @ViewBuilder private var detail: some View {
        switch fold.kind {
        case .appRequest, .appResult:
            let parts = fold.kind == .appResult ? TechnicalApps.parts(request: nil, result: message.content)
                : TechnicalApps.parts(request: message.metadata[TechnicalKey.appRequest] ?? message.content, result: message.metadata[TechnicalKey.appResult] ?? partner?.content)
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    OriginalText(folds: folds, key: TechnicalFolds.key(message.id, "all-\(part.title)"), text: part.text, monospaced: true)
                }
            }
        default:
            // P42's exchange card unfolds to itself.
            if message.presentation == .botMessage { BotExchangeCard(message: message) }
            else { OriginalText(folds: folds, key: TechnicalFolds.key(message.id, "all"), text: fold.original, monospaced: false) }
        }
    }
}

/// P51 rule 2: a ```swarmhub fence of a reply as one line; unfolded, the block pretty-printed.
struct FoldedBlockLine: View {
    @ObservedObject var folds: TechnicalFolds
    let key: String; let line: SwarmhubSummary.Line
    var body: some View {
        let open = folds.isOpen(key)
        VStack(alignment: .leading, spacing: 8) {
            FoldButton(open: open, summary: line.summary) { folds.toggle(key) } icon: { Image(systemName: "gearshape") }
                .font(.caption).foregroundStyle(.secondary)
            if open { OriginalText(folds: folds, key: key + "-all", text: TechnicalApps.pretty(line.block), monospaced: true) }
        }
        .contextMenu {
            Button("Copy") { copyToPasteboard(line.summary) }
            Button("Copy original") { copyToPasteboard("```swarmhub\n" + line.block + "\n```") }
        }
    }
}

private struct FoldButton<Icon: View>: View {
    let open: Bool; let summary: String; let toggle: () -> Void
    @ViewBuilder let icon: () -> Icon
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                icon()
                Text(summary).lineLimit(1).truncationMode(.tail)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(open ? "Fold" : "Show the original").accessibilityLabel(summary).accessibilityHint(open ? "Folds the original" : "Shows the original")
    }
}

/// The raw text, capped at 4 KB with "Show all".
private struct OriginalText: View {
    @ObservedObject var folds: TechnicalFolds
    let key: String; let text: String; let monospaced: Bool
    var body: some View {
        let shown = TechnicalApps.capped(text, all: folds.isOpen(key))
        VStack(alignment: .leading, spacing: 6) {
            Text(shown.text).font(monospaced ? .system(.caption, design: .monospaced) : .callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
            if shown.cut || folds.isOpen(key) {
                Button(folds.isOpen(key) ? "Show less" : "Show all") { folds.toggle(key) }.buttonStyle(.link).font(.caption)
            }
        }.frame(maxWidth: 620, alignment: .leading)
    }
}
