import SwiftUI

/// P16: the line under a reply row that did not simply finish: its state, Refresh (incomplete rows), Retry (not-sent rows),
/// Plain, no animation.
struct TurnStateFooter: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage

    static func isShown(for message: ChatMessage) -> Bool {
        guard message.role == .assistant, !message.isStreaming else { return false }
        return text(for: message) != nil
    }

    static func text(for message: ChatMessage) -> String? {
        let empty = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let base = TurnOutcome.footer(state: message.turnState, why: message.metadata[TurnKey.why], ambiguous: message.metadata[TurnKey.ambiguous] == "1", empty: empty)
        return base
    }

    var body: some View {
        HStack(spacing: 10) {
            if let text = Self.text(for: message) { Text(text) }
            if message.turnState == .notSent, store.canRetry(message) {
                Button(message.metadata[TurnKey.retry] == "confirm" ? "Send again (it may arrive twice)" : "Retry") { store.retry(message) }
                    .accessibilityLabel("Retry sending this message")
            }
        }
        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
    }
}

extension AppStore {
    /// The sidebar badge: a last reply that failed (`notSent`) or is `incomplete` and not streaming.
    func needsAttention(_ bot: Bot) -> Bool {
        guard let last = bot.messages.last(where: { $0.role == .assistant }), !last.isStreaming else { return false }
        return last.turnState == .notSent || last.turnState == .incomplete
    }
}
