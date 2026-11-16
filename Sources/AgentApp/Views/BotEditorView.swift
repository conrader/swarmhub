import SwiftUI

/// An agent's settings: avatar, name, instructions and one notification switch, then everything else
/// folded under Advanced (`BotEditorAdvancedSection`). Saving without opening Advanced keeps every Advanced field as stored.
struct BotEditorView: View {
    @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var store: AppStore; let bot: Bot?
    @State private var fields = BotEditorFields()
    @State private var avatarTouched = false
    @State private var newAvatarSeed = UUID().uuidString.lowercased()
    @State private var showAdvanced: Bool
    init(bot: Bot?, startExpanded: Bool = false) { self.bot = bot; _showAdvanced = State(initialValue: startExpanded) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(bot == nil ? SimpleCopy.newAgent : SimpleCopy.agentSettings).font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain) }.padding(20)
            Divider(); Form {
                Section(SimpleCopy.avatar) { AvatarPickerView(choice: Binding(get: { fields.avatar }, set: { fields.avatar = $0; avatarTouched = true }), seed: bot?.avatarSeed ?? newAvatarSeed) }
                TextField(SimpleCopy.name, text: $fields.name)
                Section(SimpleCopy.instructions) {
                    TextEditor(text: $fields.persona).frame(height: 90)
                    Text(SimpleCopy.herdrInstructionsCaption).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(SimpleCopy.notifyAgent, isOn: $fields.notifications)
                Section {
                    DisclosureGroup(isExpanded: $showAdvanced) { Text(SimpleCopy.herdrEditorAdvancedCaption).font(.caption).foregroundStyle(.secondary) } label: { Text(SimpleCopy.editorAdvanced) }
                }
                if showAdvanced { BotEditorAdvancedSection(bot: bot, fields: $fields) }
            }.formStyle(.grouped).padding(.horizontal, 8)
            Divider(); HStack { Spacer(); Button(SimpleCopy.cancel) { dismiss() }; Button(SimpleCopy.save) { save() }.buttonStyle(.borderedProminent).disabled(fields.name.trimmingCharacters(in: .whitespaces).isEmpty) }.padding(16)
        }.frame(width: 560, height: 720).background(AppColor.panel).onAppear {
            fields = bot.map(BotEditorFields.init(bot:)) ?? .newAgent(avatarSeed: newAvatarSeed)
        }
    }
    private func save() {
        if let bot {
            fields.apply(to: bot, store: store, avatarTouched: avatarTouched); store.save()
        } else {
            store.addBot(name: fields.name, persona: fields.persona, backend: fields.backend, avatarName: nil, avatar: fields.avatar)
        }
        dismiss()
    }
}

/// The editor's values, read from a bot and written back in one place, so a Save that never opened Advanced
/// writes every Advanced field exactly as it was read.
struct BotEditorFields {
    var name = "", title = "Personal agent", details = "", persona = "You are a thoughtful, capable assistant."
    var backend = BackendKind.herdr
    var avatar = AvatarChoice.unpicked
    var hidden = false, notifications = true
    /// The bot is its server's main bot.
    var canManage = false

    init() {}
    /// A new agent runs on Herdr.
    static func newAgent(avatarSeed: String = UUID().uuidString.lowercased()) -> BotEditorFields {
        var fields = BotEditorFields()
        let mark = GrokDefaultLook.mark(for: avatarSeed)
        fields.avatar = .mark(shape: mark.shape, colour: mark.colour)
        return fields
    }
    init(bot: Bot) {
        name = bot.name; title = bot.title; details = bot.botDescription; persona = bot.persona; backend = bot.backend
        avatar = AvatarChoice(bot: bot); hidden = bot.isHidden; notifications = bot.notificationsEnabled
        canManage = bot.canManageBots
    }

    @MainActor func apply(to bot: Bot, store: AppStore, avatarTouched: Bool) {
        bot.name = name; bot.title = title; bot.botDescription = details; bot.persona = persona
        if avatarTouched { avatar.apply(to: bot) }
        if bot.isHidden != hidden { store.setHidden(bot, hidden) }
        bot.notificationsEnabled = notifications
        let manages = canManage && bot.backend == .herdr
        if bot.canManageBots != manages { store.setCanManageBots(bot, manages) }
    }
}
