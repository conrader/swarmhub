import SwiftUI

struct GoalStatusView: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let goal: ChatGoal

    private var status: String {
        if goal.state == .running, store.herdrWaits(bot).waits { return "Waiting for you" }
        return goal.state.rawValue.capitalized
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Goal · \(status)").font(.caption.weight(.semibold))
                Text(goal.objective).lineLimit(2).help(goal.objective)
                if !goal.detail.isEmpty { Text(goal.detail).font(.caption).lineLimit(2).help(goal.detail) }
            }.accessibilityElement(children: .combine)
            Spacer()
            if goal.state == .waiting {
                Button("Resume") { store.resumeGoal(in: bot) }
                    .disabled(!store.isIdle(bot) || !store.goalDestinationMatches(bot) || store.herdrWaits(bot).waits)
                    .accessibilityLabel("Resume goal")
            }
            if goal.state.active {
                Button("Stop goal") { store.stopGoal(in: bot) }
            }
        }
        .controlSize(.small).padding(.horizontal, 32).padding(.top, 8).frame(maxWidth: 768)
    }
}
