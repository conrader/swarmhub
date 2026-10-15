import SwiftUI

/// Settings → Advanced → Chats (P45): how long a chat's `/goal` may run before SwarmHub stops sending rounds.
struct SettingsChatsPane: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        let budget = store.goalBudget
        Section("Goals") {
            Stepper("At most \(budget.rounds) rounds", value: Binding(get: { store.goalBudget.rounds }, set: { setBudget(rounds: $0) }), in: 1...200)
            Stepper("At most \(AppStore.hours(budget.hours * 3600))", value: Binding(get: { store.goalBudget.hours }, set: { setBudget(hours: $0) }), in: 0.5...24, step: 0.5)
            Text("A goal ends when the bot reports it done or blocked, when you pause, clear or stop it, after a failed turn, or at whichever limit comes first. New goals use these limits.")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("chats.goalBudget")
    }
    private func setBudget(rounds: Int? = nil, hours: Double? = nil) {
        if let rounds { store.defaults.set(rounds, forKey: GoalProtocol.roundsKey) }
        if let hours { store.defaults.set(hours, forKey: GoalProtocol.hoursKey) }
        store.objectWillChange.send()
    }
}
