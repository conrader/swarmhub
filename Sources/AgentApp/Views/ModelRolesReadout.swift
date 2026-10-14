import SwiftUI

/// The Overview's role lines under P11's per-chat picker: Conversation, Coding threads and Sub-agents for this bot,
/// with where each value lives. Static text; every decision comes from `ModelRolesModel`.
struct ModelRolesReadout: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: BotInfoCache
    @State private var confirming = false
    @State private var confirmingBoxDefault = false
    @State private var runtime: HermesRuntime?

    var body: some View {
        let row = store.modelRolesRow(for: bot)
        let catalog = store.modelCatalog(for: bot).value
        let ranOn = ModelRolesModel.ranOn(runtime, lock: bot.hermesModelLock, sessionID: bot.hermesSessionID, catalog: catalog)
        let unpin = catalog?.pinning == .permanent ? ModelRoleReason.permanent.text : nil
        VStack(alignment: .leading, spacing: 3) {
            if let ranOn {
                Text(ranOn.line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let mismatch = ranOn.mismatch {
                    Text(mismatch).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    let note = ModelRolesModel.boxDefaultNote(catalog: catalog)
                    Button("Use the box default instead") { confirmingBoxDefault = true }.controlSize(.small)
                        .disabled(note == nil || row.blocked != nil || cache.info(for: bot.id)?.isSwitchingModel == true)
                        .confirmationDialog("Use the box default instead?", isPresented: $confirmingBoxDefault) {
                            Button("Use the box default instead") { Task { await store.useBoxDefault(for: bot) } }
                        } message: { Text([note, unpin].compactMap { $0 }.joined(separator: " ")) }
                }
            }
            ForEach([row.conversation, row.coding].compactMap { $0 }, id: \.title) { line in
                Text(line.text).font(.caption).foregroundStyle(.secondary).accessibilityLabel(line.accessibilityLabel)
                if let note = line.note { Text(note).font(.caption2).foregroundStyle(.orange) }
            }
            Text("Sub-agents: \(ModelRoleReason.boxOnly.text)").font(.caption).foregroundStyle(.secondary)
            if row.delegationListed {
                Text(row.delegation == false ? ModelRoleReason.subAgentsOff.text : "Delegation toolset: \(row.subAgents).").font(.caption2).foregroundStyle(.tertiary)
            }
            if let mismatch = row.mismatch {
                Text(mismatch).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                if let note = row.switchNote { Text(note).font(.caption2).foregroundStyle(.secondary) }
                Button("Switch this chat") { confirming = true }.controlSize(.small).disabled(!row.canSwitch)
                    .confirmationDialog("Switch this chat?", isPresented: $confirming) {
                        Button("Switch this chat") { Task { await store.switchChatToRoleModel(for: bot) } }
                    } message: { Text([row.switchNote, unpin].compactMap { $0 }.joined(separator: " ")) }
                if let blocked = row.blocked { Text(blocked.text).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .task(id: "\(bot.hermesSessionID ?? "")|\(bot.messages.last?.id.uuidString ?? "")|\(store.isIdle)|\(bot.hermesModelLock?.model ?? "")") {
            runtime = await store.lastRuntime(for: bot)
        }
    }
}
