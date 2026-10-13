import SwiftUI

/// The Overview's role lines under P11's per-chat picker: Conversation, Coding threads and Sub-agents for this bot,
/// with where each value lives. Static text; every decision comes from `ModelRolesModel`.
struct ModelRolesReadout: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: BotInfoCache

    var body: some View {
        let row = store.modelRolesRow(for: bot)
        VStack(alignment: .leading, spacing: 3) {
            ForEach([row.conversation, row.coding].compactMap { $0 }, id: \.title) { line in
                Text(line.text).font(.caption).foregroundStyle(.secondary).accessibilityLabel(line.accessibilityLabel)
            }
            Text("Sub-agents: \(ModelRoleReason.boxOnly.text)").font(.caption).foregroundStyle(.secondary)
            if row.delegationListed {
                Text(row.delegation == false ? ModelRoleReason.subAgentsOff.text : "Delegation toolset: \(row.subAgents).").font(.caption2).foregroundStyle(.tertiary)
            }
            if let mismatch = row.mismatch { Text(mismatch).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}
