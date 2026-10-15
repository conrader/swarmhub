import SwiftUI

/// P45: the strip under a chat's header while it has a goal, a loop or a heartbeat ("Goal: … · round 3/20 · Pause · Clear").
struct AutomationStrip: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot; let conversation: any Conversation
    var body: some View {
        let automation = store.automations[conversation.id]
        if let automation, automation.goal?.isActive == true || automation.loop != nil || automation.heartbeat != nil {
            HStack(spacing: 8) {
                if let goal = automation.goal, goal.isActive { GoalChip(goal: goal, bot: bot, conversation: conversation) }
                Spacer(minLength: 0)
            }.padding(.horizontal, ChromeMetrics.headerPadding).padding(.vertical, 6).frame(maxWidth: .infinity).background(AppColor.chat)
        }
    }
}

struct GoalChip: View {
    @EnvironmentObject private var store: AppStore
    let goal: GoalRun; let bot: Bot; let conversation: any Conversation
    var body: some View {
        AutomationChip(icon: "scope", title: goal.chipTitle, detail: goal.state == .paused ? "\(goal.progress) · paused\(goal.pausedOffline ? " (offline)" : "")" : goal.progress) {
            if goal.state == .paused { Button("Resume") { store.resumeGoal(bot: bot, conversation: conversation) } }
            else { Button("Pause") { store.goalCommand("pause", bot: bot, conversation: conversation) } }
            Button("Clear") { store.goalCommand("clear", bot: bot, conversation: conversation) }
        }.accessibilityIdentifier("chat.goalChip")
    }
}

/// A capsule with an icon, a title, a detail and its buttons.
struct AutomationChip<Actions: View>: View {
    let icon: String; let title: String; let detail: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.tail).frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Text("· " + detail).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            HStack(spacing: 2) { actions() }.buttonStyle(.borderless).controlSize(.small)
        }.font(.system(size: 12)).padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 4)
            .background(AppColor.card, in: Capsule()).overlay(Capsule().stroke(AppColor.separator, lineWidth: 0.5))
    }
}

/// "Goal reached" (with the summary), "Goal blocked" (what is needed, Resume) and "Goal stopped: …".
struct AutomationCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    let actionTarget: ConversationActionTarget?
    var body: some View {
        let card = message.metadata[AutomationKey.card] ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Label(message.content, systemImage: card == "goalDone" ? "checkmark.seal.fill" : card == "goalBlocked" ? "hand.raised.fill" : "stop.circle")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(card == "goalDone" ? Color.green : card == "goalBlocked" ? Color.orange : Color.secondary)
            if let detail = message.metadata[AutomationKey.detail] { Text(detail).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if card == "goalBlocked", let (bot, conversation) = target, store.goal(in: conversation)?.state == .blocked {
                Button("Resume") { store.resumeGoal(bot: bot, conversation: conversation) }.controlSize(.small)
            }
        }.padding(12).frame(maxWidth: 520, alignment: .leading)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.separator, lineWidth: 0.5))
    }
    private var target: (Bot, any Conversation)? {
        guard case .bot(let botID, let threadID) = actionTarget, let bot = store.bots.first(where: { $0.id == botID }) else { return nil }
        if let threadID { return bot.threads.first { $0.id == threadID }.map { (bot, $0) } }
        return (bot, bot)
    }
}

enum AutomationCopy {
    /// The caption over a message SwarmHub sent by itself: "Woken by: goal".
    static func wokenBy(_ message: ChatMessage) -> String? { message.metadata[AutomationKey.woken].map { "Woken by: \($0)" } }
}
