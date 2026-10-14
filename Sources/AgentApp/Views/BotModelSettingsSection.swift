import SwiftUI

/// A role picker: leading rows ("<app name> default (…)", "Agent default (…)") then P11's supplier groups from one
/// agent's own list. Unavailable models stay visible and disabled; a read-only list disables every row. Static menu, no animation.
struct RoleModelMenu: View {
    let label: String
    let leading: [(title: String, setting: ModelSetting)]
    let picker: ModelPickerModel?
    var enabled = true
    let select: (ModelSetting) -> Void

    var body: some View {
        Menu {
            ForEach(leading.indices, id: \.self) { index in Button(leading[index].title) { select(leading[index].setting) }.disabled(!enabled) }
            ForEach(picker?.groups ?? []) { group in
                if group.usesSubmenu { Menu(group.title) { items(group) } } else { Section(group.title) { items(group) } }
            }
        } label: { Text(label) }
            .fixedSize().help(enabled ? ModelRoleReason.permanent.text : "")
    }

    @ViewBuilder private func items(_ group: ModelPickerModel.Group) -> some View {
        ForEach(group.items) { item in
            Button(item.detail.map { "\(item.model)  \($0)" } ?? item.model) {
                if let choice = ModelChoice(provider: item.supplierSlug, model: item.model) { select(.choice(choice)) }
            }
            .disabled(!enabled || item.disabledReason != nil).accessibilityLabel(item.accessibilityLabel)
        }
    }
}

/// The bot editor's Models section (Conversation role; Coding comes with coding threads). Every choice comes from
/// this agent's own backend (P17), read when the editor opens; decisions live in `RoleModelEditorModel`.
struct BotModelSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var cache: BotInfoCache
    let bot: Bot?
    let pendingBackend: BackendKind
    @Binding var conversation: ModelSetting

    var body: some View {
        let model = editorModel
        Section("Models") {
            if model.showsMenu, let bot {
                HStack {
                    Text("Conversation model")
                    Spacer()
                    RoleModelMenu(label: model.label, leading: model.leading.map { ($0.title, $0.setting) }, picker: store.modelPicker(for: bot),
                                  enabled: model.canChoose) { conversation = $0 }
                }
            } else {
                LabeledContent("Conversation model", value: model.label)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.reason).font(.caption).foregroundStyle(.secondary)
                if model.offersRetry, let bot { Spacer(); Button("Retry") { Task { await store.loadEditorModels(for: bot, pendingBackend: pendingBackend, force: true) } }.controlSize(.small) }
            }
            if let warning = model.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if model.showsUnpinCopy {
                Text("\(ModelRolesModel.conversationHelp) Applied when a chat starts; a started chat keeps its model. \(ModelRoleReason.permanent.text)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var editorModel: RoleModelEditorModel {
        let info = bot.flatMap { cache.info(for: $0.id) }
        let refreshNote = info?.refreshError.map { error in
            "Couldn't refresh: \(error)" + (info?.modelsAsOf.map { " Showing the list from \($0.formatted(date: .omitted, time: .shortened))." } ?? "")
        }
        return RoleModelEditorModel(isNew: bot == nil, savedBackend: bot?.backend, pendingBackend: pendingBackend,
                                    catalog: bot.map { store.modelCatalog(for: $0) } ?? .loading, hasEntry: info != nil, autoLoad: cache.autoLoad,
                                    refreshNote: refreshNote, appDefault: store.modelDefaults.conversation, setting: conversation)
    }
}
