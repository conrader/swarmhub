import SwiftUI

/// Settings → Models: the two model roles per bot, what is set and where it lives. Opening the pane fetches
/// nothing; **Load** reads each profile (GETs only). Static text, no spinner, no animation.
struct SettingsModelsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var cache: BotInfoCache
    @State private var loading = false; @State private var loadedAt: Date?
    /// The bot whose profile list feeds the pickers (a view preference, not stored).
    @State private var referenceID: UUID?

    var body: some View {
        let model = store.modelRoles()
        Section {
            Text(ModelRolesModel.caption).font(.caption).foregroundStyle(.secondary)
            HStack {
                if let loadedAt { Text("Read from the box \(loadedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                else if !loading { Text("Press Load to read each bot's profile.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if loading { Text("Loading…").font(.caption).foregroundStyle(.secondary) }
                Button(loadedAt == nil ? "Load" : "Refresh") { load() }.disabled(loading || model.hermesRows.isEmpty)
            }
        }
        Section("All bots") {
            conversationDefault(model)
            roleDefault("Coding model", value: "Same as conversation", help: ModelRolesModel.codingHelp)
        }
        if model.rows.isEmpty {
            Text("No bot is bound to a Hermes profile.").foregroundStyle(.secondary)
        }
        ForEach(model.servers, id: \.server) { server in
            Section("Per bot · \(server.server)") { ForEach(server.rows) { row in botRow(row) } }
        }
        Section("Set on the box (read-only)") {
            boxLine("Box default", model.fleetSummary, note: nil)
            boxLine("Sub-agents", model.subAgentSummary, note: ModelRoleReason.boxOnly.text)
            boxLine("Compaction", nil, note: ModelRoleReason.boxOnly.text)
            boxLine("Routines", nil, note: ModelRoleReason.boxOnly.text)
        }
    }

    @ViewBuilder private func conversationDefault(_ model: ModelRolesModel) -> some View {
        let loaded = model.hermesRows.filter { cache.info(for: $0.id)?.modelOptions.value != nil }
        let reference = store.bots.first { $0.id == (referenceID ?? loaded.first?.id) }
        if !loaded.isEmpty {
            Picker("Models from", selection: Binding(get: { reference?.id }, set: { referenceID = $0 })) {
                ForEach(loaded) { row in Text(row.name).tag(row.id as UUID?) }
            }
        }
        HStack {
            Text("Conversation model")
            Spacer()
            RoleModelMenu(label: store.modelDefaults.conversation?.model ?? "Box default", leading: [("Box default", .box)],
                          picker: reference.map { store.modelPicker(for: $0) }) { setting in
                if case .choice(let choice) = setting { store.modelDefaults.conversation = choice } else { store.modelDefaults.conversation = nil }
                store.save()
            }
        }
        Text(ModelRolesModel.conversationHelp + (loaded.isEmpty ? " Press Load to list the box's models." : "") + " " + ModelRoleReason.permanent.text)
            .font(.caption).foregroundStyle(.secondary)
    }

    private func roleDefault(_ title: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: value)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func botRow(_ row: ModelRolesModel.Row) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                if row.isOpenClaw { Text(ModelRoleReason.openClaw.text).font(.caption).foregroundStyle(.secondary) }
                else {
                    Text("Profile \(row.profile)").font(.caption2).foregroundStyle(.tertiary)
                    ForEach([row.conversation, row.coding].compactMap { $0 }, id: \.title) { line in
                        Text(line.text).font(.caption).foregroundStyle(.secondary).accessibilityLabel(line.accessibilityLabel)
                    }
                    if let error = row.loadError { Text(error).font(.caption2).foregroundStyle(.orange) }
                    if let blocked = row.blocked { Text(blocked.text).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if let bot = store.bots.first(where: { $0.id == row.id }) { Button("Edit…") { store.editingBot = bot } }
        }
        .opacity(row.isOpenClaw ? 0.5 : 1)
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
