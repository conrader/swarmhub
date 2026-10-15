import SwiftUI

/// P31 D: a Hermes bot's "Coding model:" line (Overview and Settings → Models): `delegation.model` as the manager last
/// reported it, "Check" while nothing is reported, and "Change…" (the coding model sheet, this bot
/// prefilled) when its connection has a Hermes manager.
struct SubAgentLineView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var delegationOff = false
    /// The sheet opens over the window this line is in (main window or Settings).
    @State private var sheet: SubAgentModelRequest?

    var body: some View {
        let target = store.connection(of: bot)
        let line = store.subAgentLine(for: bot, delegationOff: delegationOff)
        let manager = store.manager(for: bot).flatMap { $0.backend == .hermes ? $0 : nil }
        let checking = store.boxChecks.contains(.models(target))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer(minLength: 4)
                if checking { ProgressView().controlSize(.mini) }
                if line.offersCheck { Button("Check") { Task { await store.checkModels(on: target) } }.controlSize(.small).disabled(checking) }
                if let manager, !delegationOff {
                    Button("Change…") { sheet = SubAgentModelRequest(managerID: manager.id, profile: bot.hermesProfile ?? "default") }
                        .controlSize(.small)
                }
            }
            if let problem = store.boxCheckProblems[.models(target)] { Text(problem).font(.caption2).foregroundStyle(.orange) }
        }
        .sheet(item: $sheet) { SubAgentModelSheet(request: $0).environmentObject(store) }
    }
}
