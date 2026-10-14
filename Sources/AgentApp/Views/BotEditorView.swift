import SwiftUI

/// An agent's settings (P21 Part B): avatar, name, instructions and one notification switch, then everything else
/// folded under Advanced (`BotEditorAdvancedSection`). Saving without opening Advanced keeps every Advanced field as stored.
struct BotEditorView: View {
    @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var store: AppStore; let bot: Bot?
    @State private var fields = BotEditorFields()
    @State private var avatarTouched = false
    @State private var showAdvanced: Bool
    init(bot: Bot?, startExpanded: Bool = false) { self.bot = bot; _showAdvanced = State(initialValue: startExpanded) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(bot == nil ? SimpleCopy.newAgent : SimpleCopy.agentSettings).font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain) }.padding(20)
            Divider(); Form {
                Section(SimpleCopy.avatar) { AvatarPickerView(choice: Binding(get: { fields.avatar }, set: { fields.avatar = $0; avatarTouched = true })) }
                TextField(SimpleCopy.name, text: $fields.name)
                Section(SimpleCopy.instructions) {
                    TextEditor(text: $fields.persona).frame(height: 90)
                    Text(SimpleCopy.instructionsCaption).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(SimpleCopy.notifyAgent, isOn: $fields.notifications)
                Section {
                    DisclosureGroup(isExpanded: $showAdvanced) { Text(SimpleCopy.editorAdvancedCaption).font(.caption).foregroundStyle(.secondary) } label: { Text(SimpleCopy.editorAdvanced) }
                }
                if showAdvanced { BotEditorAdvancedSection(bot: bot, fields: $fields) }
            }.formStyle(.grouped).padding(.horizontal, 8)
            Divider(); HStack { Spacer(); Button(SimpleCopy.cancel) { dismiss() }; Button(SimpleCopy.save) { save() }.buttonStyle(.borderedProminent).disabled(fields.name.trimmingCharacters(in: .whitespaces).isEmpty) }.padding(16)
        }.frame(width: 560, height: 720).background(AppColor.panel).onAppear {
            fields = bot.map(BotEditorFields.init(bot:)) ?? .newAgent(hermesConfigured: store.hermesConfigured)
        }
    }
    private func save() {
        if let bot {
            fields.apply(to: bot, store: store, avatarTouched: avatarTouched); store.save()
        } else {
            store.addBot(name: fields.name, persona: fields.persona, backend: fields.backend, avatarName: nil, avatar: fields.avatar, approvalMode: fields.approvalMode, approvalRules: fields.approvalRules, reviewerBotID: fields.reviewerBotID)
        }
        dismiss()
    }
}

/// The editor's values, read from a bot and written back in one place, so a Save that never opened Advanced
/// writes every Advanced field exactly as it was read.
struct BotEditorFields {
    var name = "", title = "Personal agent", details = "", persona = "You are a thoughtful, capable assistant."
    var backend = BackendKind.mock
    var avatar = AvatarChoice.unpicked
    var hidden = false, notifications = true
    var approvalMode = ApprovalMode.ask, approvalRules = ApprovalRule.sensibleDefaults, reviewerBotID: UUID?
    var conversationModel = ModelSetting.inherit, canManage = false

    init() {}
    /// A new agent talks to the box when one is configured; Mock stays reachable only under Advanced.
    static func newAgent(hermesConfigured: Bool) -> BotEditorFields { var fields = BotEditorFields(); fields.backend = hermesConfigured ? .hermes : .mock; return fields }
    init(bot: Bot) {
        name = bot.name; title = bot.title; details = bot.botDescription; persona = bot.persona; backend = bot.backend
        avatar = AvatarChoice(bot: bot); hidden = bot.isHidden; notifications = bot.notificationsEnabled
        approvalMode = bot.approvalMode; approvalRules = bot.approvalRules; reviewerBotID = bot.reviewerBotID
        conversationModel = bot.modelSettings?.conversation ?? .inherit; canManage = bot.canManageBots
    }

    @MainActor func apply(to bot: Bot, store: AppStore, avatarTouched: Bool) {
        bot.name = name; bot.title = title; bot.botDescription = details; bot.persona = persona; bot.backend = backend
        if avatarTouched { avatar.apply(to: bot) }
        if bot.isHidden != hidden { store.setHidden(bot, hidden) }
        bot.notificationsEnabled = notifications; bot.approvalMode = approvalMode; bot.approvalRules = approvalRules
        bot.reviewerBotID = reviewerBotID == bot.id ? nil : reviewerBotID
        var settings = bot.modelSettings ?? .init(); settings.conversation = conversationModel
        bot.modelSettings = settings.isEmpty ? nil : settings
        if bot.canManageBots != (canManage && backend == .hermes) { store.setCanManageBots(bot, canManage && backend == .hermes) }
    }
}
