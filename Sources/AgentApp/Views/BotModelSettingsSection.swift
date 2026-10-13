import SwiftUI

/// A role picker: leading rows ("Box default", "Use <app name> default (…)") then P11's supplier groups from one
/// profile's list. Unavailable models stay visible and disabled. Static menu, no animation.
struct RoleModelMenu: View {
    let label: String
    let leading: [(title: String, setting: ModelSetting)]
    let picker: ModelPickerModel?
    let select: (ModelSetting) -> Void

    var body: some View {
        Menu {
            ForEach(leading.indices, id: \.self) { index in Button(leading[index].title) { select(leading[index].setting) } }
            ForEach(picker?.groups ?? []) { group in
                if group.usesSubmenu { Menu(group.title) { items(group) } } else { Section(group.title) { items(group) } }
            }
        } label: { Text(label) }
            .fixedSize().help(ModelRoleReason.permanent.text)
    }

    @ViewBuilder private func items(_ group: ModelPickerModel.Group) -> some View {
        ForEach(group.items) { item in
            Button(item.detail.map { "\(item.model)  \($0)" } ?? item.model) {
                if let choice = ModelChoice(provider: item.supplierSlug, model: item.model) { select(.choice(choice)) }
            }
            .disabled(item.disabledReason != nil).accessibilityLabel(item.accessibilityLabel)
        }
    }
}

/// The bot editor's Models section (Conversation role; Coding comes with coding threads). Validated against this
/// bot's own profile list, never at save time against another bot's.
struct BotModelSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var cache: BotInfoCache
    let bot: Bot?
    @Binding var conversation: ModelSetting

    var body: some View {
        let appDefault = "Use \(AppConstants.name) default (\(store.modelDefaults.conversation?.model ?? "box default"))"
        Section("Models") {
            if let bot, bot.backend == .hermes, bot.hermesProfile != nil {
                let options = cache.info(for: bot.id)?.modelOptions.value
                HStack {
                    Text("Conversation model")
                    Spacer()
                    RoleModelMenu(label: label(appDefault), leading: [(appDefault, .inherit), ("Box default", .box)],
                                  picker: options == nil ? nil : store.modelPicker(for: bot)) { conversation = $0 }
                }
                if options == nil { Button("Load this bot's models") { Task { await store.loadServerInfo(for: bot, includeSkills: false) } } }
                if case .choice(let choice) = conversation, let options, !ModelPickerModel.offers(options, choice) {
                    Text(ModelRoleReason.notOffered(choice.model).text).font(.caption).foregroundStyle(.orange)
                }
                Text("\(ModelRolesModel.conversationHelp) Applied when a chat starts; a started chat keeps its model. \(ModelRoleReason.permanent.text)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Conversation model", value: appDefault)
                Text("Other choices appear once the bot is bound to a Hermes profile.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ appDefault: String) -> String {
        switch conversation {
        case .inherit: appDefault
        case .box: "Box default"
        case .choice(let choice): choice.model
        }
    }
}
