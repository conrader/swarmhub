import SwiftUI

struct GoalStatusView: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let goal: ChatGoal

    private var status: String {
        if bot.sampleProfile != nil, goal.state == .waiting { return "Watching sample" }
        if goal.state == .running, store.herdrWaits(bot).waits { return "Waiting for you" }
        return goal.state.rawValue.capitalized
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Goal · \(status)").font(.caption.weight(.semibold))
                if let steps = goal.stepProgress { Text(steps).font(.caption) }
                if let spend = goal.spendProgress { Text(spend).font(.caption).help(bot.sampleProfile != nil ? "Offline sample steps cost $0." : "OpenCode reports an estimate. A step already running may exceed the limit.") }
                Text(goal.objective).lineLimit(2).help(goal.objective)
                if !goal.detail.isEmpty { Text(goal.detail).font(.caption).lineLimit(2).help(goal.detail) }
                if goal.serverGoal != nil, goal.state.active {
                    Text("Runs on the server, also while SwarmHub is closed.").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .combine)
            Spacer()
            if goal.state == .waiting && bot.sampleProfile == nil {
                Button("Resume") { store.resumeGoal(in: bot) }
                    .disabled(goal.serverGoal == nil && (!store.isIdle(bot) || !store.goalDestinationMatches(bot) || store.herdrWaits(bot).waits))
                    .accessibilityLabel("Resume goal")
            }
            if goal.state.active {
                Button("Stop goal") { store.stopGoal(in: bot) }
            } else {
                Button("Dismiss") { store.dismissGoal(in: bot) }
                    .accessibilityLabel("Dismiss goal status")
            }
        }
        .controlSize(.small).padding(.horizontal, 32).padding(.top, 8).frame(maxWidth: 768)
    }
}
