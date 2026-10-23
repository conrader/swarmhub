import SwiftUI

/// Suggested replies under a bot message (recs1): each chip sends its text as the user's reply in that chat, exactly as if
/// typed; typing anything else works too. The chips show only until something answers the message.
struct SuggestedRepliesRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    /// Where the reply goes; nil (renders, a thread's parent line) shows no chips.
    let target: ConversationActionTarget?

    var body: some View {
        if let target, store.canSendSuggestedReply(on: message, target: target) {
            let busy = store.isStreaming(for: target)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips(target, busy: busy) }
                VStack(alignment: .leading, spacing: 6) { chips(target, busy: busy) }
            }.accessibilityElement(children: .contain).accessibilityLabel("Suggested replies")
        }
    }

    @ViewBuilder private func chips(_ target: ConversationActionTarget, busy: Bool) -> some View {
        ForEach(message.suggestedReplies, id: \.self) { reply in
            Button { store.sendSuggestedReply(reply, on: message, target: target) } label: {
                Text(reply).font(.callout).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 6).contentShape(Capsule())
                    .background(AppColor.raised, in: Capsule()).overlay(Capsule().stroke(AppColor.separator, lineWidth: 0.5))
            }.buttonStyle(.plain).disabled(busy).help("Send “\(reply)”")
        }
    }
}
