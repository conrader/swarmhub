import SwiftUI

/// P16: the line under a reply row that did not simply finish: its state, Refresh (incomplete rows), Retry (not-sent rows),
/// "Checking the box…" while a pass runs, and "Restored from the box" on rows the box repaired. Plain, no animation.
struct TurnStateFooter: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage

    static func isShown(for message: ChatMessage) -> Bool {
        guard message.role == .assistant, !message.isStreaming else { return false }
        return text(for: message) != nil || message.metadata[TurnKey.restored] != nil || message.metadata[TurnKey.check] != nil
    }

    static func text(for message: ChatMessage) -> String? {
        let empty = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let base = TurnOutcome.footer(state: message.turnState, why: message.metadata[TurnKey.why], ambiguous: message.metadata[TurnKey.ambiguous] == "1", empty: empty)
        guard message.turnState == .incomplete, let end = message.metadata[TurnKey.end] else { return base }
        return end == "error" ? "The box ended this reply with an error" : "The box has no more of this reply"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let text = Self.text(for: message) { Text(text) }
            if let check = message.metadata[TurnKey.check] { Text(check == "checking" ? "Checking the box…" : check) }
            else if message.turnState == .incomplete, store.hasSessions(for: message) {
                Button("Refresh") { store.refresh(message) }.accessibilityLabel("Refresh this reply from the box")
            }
            if message.turnState == .notSent, message.metadata[TurnKey.check] == nil, store.canRetry(message) {
                if message.metadata[TurnKey.retry] == "blocked" {
                    Button("Send anyway") { store.retry(message, sendAnyway: true) }.accessibilityLabel("Send this message anyway")
                } else {
                    Button(message.metadata[TurnKey.retry] == "confirm" ? "Tap again to send — the box may have it" : "Retry") { store.retry(message) }
                        .accessibilityLabel("Retry sending this message")
                }
            }
            if message.metadata[TurnKey.restored] != nil { Text("Restored from the box") }
        }
        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
    }
}

extension AppStore {
    /// Refresh is hidden when the chat has no sessions to read.
    func hasSessions(for message: ChatMessage) -> Bool {
        guard let conversation = conversation(containing: message.id) else { return false }
        return !reconcileUnits(for: conversation).isEmpty
    }

    /// P20/P16 sidebar badge: a pending approval, or a last reply that failed (`notSent`) or is `incomplete` and not streaming.
    func needsAttention(_ bot: Bot) -> Bool {
        if hasPendingApproval(bot) { return true }
        guard let last = bot.messages.last(where: { $0.role == .assistant && $0.presentation == .text }), !last.isStreaming else { return false }
        return last.turnState == .notSent || last.turnState == .incomplete
    }
}
