import SwiftUI

/// In the chat header, after the model: whether the bot's agent is running. A small green dot and "Ready" when a
/// message is answered at once; a spinner and "Starting Codex…" while its agent program starts ahead of the first
/// message; a hand when the agent shows a prompt in its terminal and takes no message until the person answers
/// there. A bot with no agent shows nothing (`AppStore.herdrReadiness`).
struct HerdrReadinessMark: View {
    let readiness: HerdrAgentReadiness

    var body: some View {
        HStack(spacing: 5) {
            if readiness.isStarting {
                ProgressView().controlSize(.mini)
            } else if readiness.isBlocked {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(AppColor.caution).accessibilityHidden(true)
            } else {
                Circle().fill(AppColor.good).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(readiness.word).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(readiness.help)
        .accessibilityElement(children: .combine).accessibilityLabel(readiness.word).accessibilityHint(readiness.help)
        .accessibilityIdentifier("chat.agent_readiness")
    }
}
