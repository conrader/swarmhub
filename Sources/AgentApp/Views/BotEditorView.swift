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
    @State private var pickingAvatar = false
    @FocusState private var nameFocused: Bool
    private var seed: String { bot?.avatarSeed ?? newAvatarSeed }

    /// Made the way a contact is: a large avatar with the name typed directly under it, then what the agent should
    /// know, each setting with its heading and sentence. Return saves; Escape closes.
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(bot == nil ? SimpleCopy.newAgent : SimpleCopy.agentSettings).font(.headline)
                HStack { Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain).accessibilityLabel(SimpleCopy.cancel) }
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
                    identity
                    SettingBlock(title: SimpleCopy.instructions, detail: SimpleCopy.herdrInstructionsCaption) {
                        TextEditor(text: $fields.persona).font(.body).scrollContentBackground(.hidden).padding(8).frame(height: 110)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityLabel(SimpleCopy.instructions)
                    }
                    SettingSwitch(title: SimpleCopy.notifyAgent, symbol: "bell.badge.fill", colour: .red, isOn: $fields.notifications)
                    QuietFold(title: SimpleCopy.editorAdvanced, isOpen: $showAdvanced) { BotEditorAdvancedSection(bot: bot, fields: $fields) }
                    if !showAdvanced { Text(SimpleCopy.herdrEditorAdvancedCaption).font(.caption).foregroundStyle(.secondary).padding(.top, -18).padding(.leading, 16) }
                }.padding(.horizontal, 32).padding(.vertical, 24)
            }
            Divider()
            HStack {
                Spacer()
                Button(SimpleCopy.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(SimpleCopy.save) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(fields.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.controlSize(.large).padding(16)
        }.frame(width: 560, height: 720).background(AppColor.panel).onAppear {
            fields = bot.map(BotEditorFields.init(bot:)) ?? .newAgent(avatarSeed: newAvatarSeed)
            if bot == nil { nameFocused = true }
        }
    }

    /// The avatar as it looks (a click opens the picker), the main bot's star, and the name typed beneath.
    private var identity: some View {
        VStack(spacing: 10) {
            Button { pickingAvatar = true } label: {
                Group {
                    if case .classic(let name) = fields.avatar { AvatarImage(name: name).frame(width: 84, height: 84) }
                    else {
                        let mark = fields.avatar.previewMark(seed: seed)
                        AvatarMarkView(shape: mark.shape, colour: AvatarColour(rawValue: mark.colour) ?? .gray, size: 84, mode: .still, seed: seed)
                    }
                }
                .frame(width: 96, height: 92)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 22)).symbolRenderingMode(.palette).foregroundStyle(.white, Color.secondary)
                        .background(Circle().fill(AppColor.panel).padding(1)).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(SimpleCopy.avatar).accessibilityLabel(SimpleCopy.avatar)
            .popover(isPresented: $pickingAvatar, arrowEdge: .trailing) {
                AvatarPickerView(choice: Binding(get: { fields.avatar }, set: { fields.avatar = $0; avatarTouched = true }), seed: seed).padding(16).frame(width: 440)
            }
            HStack(spacing: 8) {
                TextField(SimpleCopy.name, text: $fields.name, prompt: Text(SimpleCopy.name))
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
                    .padding(.vertical, 6).padding(.horizontal, 14).frame(width: 300)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($nameFocused).accessibilityLabel(SimpleCopy.name)
            }
            if let bot, let main = store.herdrMainBotLabel(bot) {
                HStack(spacing: 5) { HerdrMainBotStar(label: main, size: 11); Text(main).font(.subheadline).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity)
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
