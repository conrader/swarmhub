import SwiftUI

/// The cards of one chat that are unfolded (`FoldState`), shared by its rows: a row of a lazy list is thrown away
/// when it scrolls out of sight, and its card must come back as the person left it.
@MainActor final class ChatFolds: ObservableObject {
    @Published var state: FoldState
    init(open: Set<UUID> = []) { state = FoldState(open: open) }
}

private struct ChatFoldsKey: EnvironmentKey { static let defaultValue: ChatFolds? = nil }

extension EnvironmentValues {
    /// The chat's unfolded cards; nil outside a chat, where a card keeps its own state.
    var chatFolds: ChatFolds? {
        get { self[ChatFoldsKey.self] }
        set { self[ChatFoldsKey.self] = newValue }
    }
}

/// A message the app put into this chat from another bot (its request for a new bot, its message, its answer), or
/// one this chat's bot wrote to another: folded to one row with that bot's face, who it is from and the first
/// sentence, in that bot's own colour. A click (or Space, or VoiceOver's press) unfolds the whole text in place and
/// another folds it again. The lines that only tell the agent how to answer are sent with it and never drawn
/// (`HerdrPassedOn`).
struct PassedOnCard: View {
    let row: AppStore.PassedOnRow
    @Environment(\.chatFolds) private var shared
    @StateObject private var own = ChatFolds()

    var body: some View { PassedOnFold(row: row, folds: shared ?? own) }
}

private struct PassedOnFold: View {
    let row: AppStore.PassedOnRow
    @ObservedObject var folds: ChatFolds
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isOpen: Bool { folds.state.isOpen(row.id) }
    private var colours: BotTint { row.sender?.colours ?? .app }

    var body: some View {
        let colours = colours, open = isOpen
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { folds.state.toggle(row.id) } } label: { header(open: open, colours: colours) }
                .buttonStyle(.plain)
                .help(open ? PassedOnCopy.fold : PassedOnCopy.unfold)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.summary.isEmpty ? row.title : "\(row.title). \(row.summary)")
                .accessibilityValue(open ? PassedOnCopy.unfolded : PassedOnCopy.folded)
                .accessibilityHint(open ? PassedOnCopy.fold : PassedOnCopy.unfold)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("chat.passed_on")
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = row.shown.botName { Text(name).font(.headline) }
                    if !row.shown.body.isEmpty { Text(PassedOnCopy.styled(row.shown.body)).font(.callout).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.leading, PassedOnMetrics.face + PassedOnMetrics.gap).padding(.trailing, 6).padding(.bottom, 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: PassedOnMetrics.width, alignment: .leading)
        .background(colours.fill.opacity(BotTintPair.wash + (hovering && !open ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(colours.border, lineWidth: 1))
        .onHover { hovering = $0 }
    }

    /// The row that is always there: the face, who it is from over the first sentence, and the fold mark.
    private func header(open: Bool, colours: BotTint) -> some View {
        HStack(alignment: .center, spacing: PassedOnMetrics.gap) {
            if let sender = row.sender { BotAvatar(bot: sender, size: PassedOnMetrics.face) }
            else {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(colours.ink)
                    .frame(width: PassedOnMetrics.face, height: PassedOnMetrics.face).background(Circle().fill(colours.fill.opacity(0.18))).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.caption.weight(.semibold)).foregroundStyle(colours.ink).lineLimit(1)
                if !open, !row.summary.isEmpty {
                    // The widest cut that fits on one line: each is cut at a word, so the line never ends inside one.
                    ViewThatFits(in: .horizontal) {
                        ForEach(row.summaries, id: \.self) { line in Text(line).font(.callout).foregroundStyle(.primary).lineLimit(1).fixedSize() }
                        Text(row.summaries.last ?? "").font(.callout).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(colours.ink)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 22, height: 22)
                .background(Circle().fill(colours.fill.opacity(0.16))).accessibilityHidden(true)
        }.contentShape(Rectangle())
    }
}

enum PassedOnMetrics {
    static let face: CGFloat = 28, gap: CGFloat = 10, width: CGFloat = 560
}

enum PassedOnCopy {
    static let unfold = "Show the whole message", fold = "Fold the message"
    static let folded = "Folded", unfolded = "Unfolded"

    /// The words as written, with `code` and **bold** drawn as such; every line break stays where it is.
    static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

extension AppStore.PassedOnRow {
    var summary: String { shown.summary }
    /// The folded line at several lengths, longest first, each cut at a word.
    var summaries: [String] {
        var seen: Set<String> = []
        return [HerdrPassedOn.summaryLength, 90, 72, 56, 42, 30, 20].map { shown.summary(limit: $0) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
