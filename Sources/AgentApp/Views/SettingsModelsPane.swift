import SwiftUI

/// Settings → Models: the two model roles per bot, what is set and where it lives, each from that agent's own list
/// (P17). Opening the pane fetches nothing; **Load** reads each agent (GETs only). Static text, no spinner, no animation.
struct SettingsModelsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var cache: BotInfoCache
    @State private var loading = false; @State private var loadedAt: Date?
    /// The bot whose profile list feeds the pickers (a view preference, not stored).
    @State private var referenceID: UUID?
    /// "Switch existing chats…": the preview taken when the button was pressed (nothing is sent before Confirm).
    @State private var plan: ModelRolesPlan?

    var body: some View {
        let model = store.modelRoles()
        Section {
            Text(ModelRolesModel.caption).font(.caption).foregroundStyle(.secondary)
            HStack {
                if let loadedAt { Text("Read from the box \(loadedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                else if !loading { Text("Press Load to read each bot's profile.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if loading { Text("Loading…").font(.caption).foregroundStyle(.secondary) }
                Button(loadedAt == nil ? "Load" : "Refresh") { load() }.disabled(loading || model.askableRows.isEmpty)
            }
        }
        Section("All bots") {
            roleDefaults(model)
            let preview = store.modelRolesPlan()
            Button("Switch existing chats… (\(preview.countText))") { plan = preview }.disabled(loading || preview.changing.isEmpty)
            Text("Main chats only; group chats and threads keep their models. \(ModelRoleReason.permanent.text)").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $plan) { ModelRolesPlanSheet(plan: $0) }
        // P31 E: under Coding agent, how many coding jobs each Hermes box runs side by side (OpenClaw boxes show nothing).
        if !store.hermesConnections.isEmpty {
            Section("Coding jobs") {
                ForEach(store.hermesConnections, id: \.target) { connection in BoxCapacityBlock(target: connection.target, host: connection.host) }
            }
        }
        if model.rows.isEmpty {
            Text("No bot is bound to a Hermes profile.").foregroundStyle(.secondary)
        }
        ForEach(model.servers, id: \.server) { server in
            Section("Per bot · \(server.server)") { ForEach(server.rows) { row in botRow(row) } }
        }
        Section("Set on the box (read-only)") {
            boxLine("Agent default", model.fleetSummary, note: nil)
            boxLine("Sub-agents", model.subAgentSummary, note: "Each bot's coding model is under its name above.")
            boxLine("Compaction", nil, note: ModelRoleReason.boxOnly.text)
            boxLine("Routines", nil, note: ModelRoleReason.boxOnly.text)
        }
    }

    @ViewBuilder private func roleDefaults(_ model: ModelRolesModel) -> some View {
        let loaded = model.rows.filter { $0.canAsk && $0.catalog != nil }
        let referenceRow = loaded.first { $0.id == referenceID } ?? loaded.first
        let reference = store.bots.first { $0.id == referenceRow?.id }
        let permanent = referenceRow?.catalog?.pinning == .permanent
        if !loaded.isEmpty {
            Picker("Models from", selection: Binding(get: { reference?.id }, set: { referenceID = $0 })) {
                ForEach(loaded) { row in Text(row.name).tag(row.id as UUID?) }
            }
        }
        let picker = reference.map { store.modelPicker(for: $0) }, enabled = reference == nil || permanent
        defaultMenu("Conversation model", \.conversation, fallback: "Agent default", picker: picker, enabled: enabled)
        if let offered = model.offerSummary(store.modelDefaults.conversation) { Text(offered).font(.caption).foregroundStyle(.secondary) }
        if referenceRow != nil, !permanent { Text(ModelCatalog.switchingLater).font(.caption).foregroundStyle(.secondary) }
        Text(ModelRolesModel.conversationHelp + (loaded.isEmpty ? " Press Load to list each agent's models." : "") + (permanent ? " " + ModelRoleReason.permanent.text : ""))
            .font(.caption).foregroundStyle(.secondary)
        defaultMenu("Coding model", \.coding, fallback: RoleModelEditorModel.sameAsConversation, picker: picker, enabled: enabled)
        if let offered = model.offerSummary(store.modelDefaults.coding) { Text(offered).font(.caption).foregroundStyle(.secondary) }
        Text(ModelRolesModel.codingHelp).font(.caption).foregroundStyle(.secondary)
        if let hint = ModelRolesModel.sharedSupplierHint(conversation: store.modelDefaults.conversation, coding: store.modelDefaults.coding, catalog: referenceRow?.catalog) {
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        // P31 D1: the SwarmHub-wide coding agent order; a bot's own choice in its editor wins.
        Picker("Coding agent", selection: Binding(get: { store.modelDefaults.codingAgent ?? .standard },
                                                  set: { store.modelDefaults.codingAgent = $0 == .standard ? nil : $0; store.save() })) {
            ForEach(CodingOrder.allCases) { Text($0.title).tag($0) }
        }
        Text(CodingOrder.help + " A bot can choose its own in its settings.").font(.caption).foregroundStyle(.secondary)
    }

    private func defaultMenu(_ title: String, _ role: WritableKeyPath<ModelDefaults, ModelChoice?>, fallback: String, picker: ModelPickerModel?, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            RoleModelMenu(label: store.modelDefaults[keyPath: role]?.model ?? fallback, leading: [(fallback, .box)], picker: picker, enabled: enabled) { setting in
                if case .choice(let choice) = setting { store.modelDefaults[keyPath: role] = choice } else { store.modelDefaults[keyPath: role] = nil }
                store.save()
            }
        }
    }

    @ViewBuilder private func botRow(_ row: ModelRolesModel.Row) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                if !row.canAsk { Text(row.catalogReason ?? ModelRoleReason.openClaw.text).font(.caption).foregroundStyle(.secondary) }
                else {
                    Text(row.catalog?.detail ?? "Profile \(row.profile)").font(.caption2).foregroundStyle(.tertiary)
                    ForEach([row.conversation, row.coding].compactMap { $0 }, id: \.title) { line in
                        Text(line.text).font(.caption).foregroundStyle(.secondary).accessibilityLabel(line.accessibilityLabel)
                        if let note = line.note { Text(note).font(.caption2).foregroundStyle(.orange) }
                    }
                    if row.catalog == nil, let reason = row.catalogReason, row.loadError == nil, row.boxDefault == nil, reason != "not loaded" { Text(reason).font(.caption2).foregroundStyle(.secondary) }
                    if let readOnly = row.readOnly { Text(readOnly).font(.caption2).foregroundStyle(.secondary) }
                    if let error = row.loadError { Text(error).font(.caption2).foregroundStyle(.orange) }
                    if let blocked = row.blocked { Text(blocked.text).font(.caption2).foregroundStyle(.secondary) }
                }
                // P31 D: the sub-agent model the manager reported (read through the manager, so also before Load).
                if let bot = store.bots.first(where: { $0.id == row.id }), bot.backend == .hermes { SubAgentLineView(bot: bot, delegationOff: row.delegation == false) }
            }
            Spacer()
            if let bot = store.bots.first(where: { $0.id == row.id }) { Button("Edit…") { store.editingBot = bot } }
        }
        .opacity(row.canAsk ? 1 : 0.5)
    }

    private func boxLine(_ title: String, _ value: String?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map { "\(title): \($0)" } ?? title)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func load() {
        loading = true
        Task { await store.loadModelRoles(); loadedAt = .now; loading = false }
    }
}
