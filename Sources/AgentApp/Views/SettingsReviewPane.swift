import SwiftUI

/// Settings → Advanced → Auto-review: each bot's approval policy and its Edit… button, moved unchanged (P21).
struct SettingsReviewPane: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Section {
            Text("Approval policy is set per bot: Ask me, ordered allow/deny/ask rules, or another bot as reviewer. Unsafe or destructive commands always come to you. Each bot’s decisions are listed in its Overview panel.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Bots") {
            ForEach(store.bots.filter { !$0.isReadOnlyArchive && !$0.isDemo }) { bot in
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(bot.name); Text(reviewSummary(bot)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Edit…") { store.editingBot = bot }
                }
            }
        }
    }
    private func reviewSummary(_ bot: Bot) -> String {
        switch bot.approvalMode {
        case .ask: return "Ask me"
        case .rules: return "Rules (\(bot.approvalRules.count))"
        case .reviewer: return "Reviewer: " + (store.bots.first { $0.id == bot.reviewerBotID }?.name ?? "not chosen — asks you")
        }
    }
}
