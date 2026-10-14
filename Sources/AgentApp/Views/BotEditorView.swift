import SwiftUI

struct BotEditorView: View {
    @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var store: AppStore; let bot: Bot?
    @State private var name = ""; @State private var title = "Personal agent"; @State private var details = ""; @State private var persona = "You are a thoughtful, capable assistant."; @State private var backend = BackendKind.mock
    @State private var avatar = AvatarChoice.unpicked; @State private var avatarTouched = false
    @State private var hidden = false; @State private var notifications = true
    @State private var approvalMode = ApprovalMode.ask; @State private var approvalRules = ApprovalRule.sensibleDefaults; @State private var reviewerBotID: UUID?
    @State private var conversationModel = ModelSetting.inherit; @State private var canManage = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(bot == nil ? "New agent" : "Agent settings").font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain) }.padding(20)
            Divider(); Form {
                Section("Avatar") { AvatarPickerView(choice: Binding(get: { avatar }, set: { avatar = $0; avatarTouched = true })) }
                TextField("Name", text: $name); TextField("Title", text: $title); TextField("Description", text: $details, axis: .vertical).lineLimit(2...4)
                Picker("Backend", selection: $backend) { ForEach(BackendKind.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Show in sidebar", isOn: Binding(get: { !hidden }, set: { hidden = !$0 })); Toggle("Notifications", isOn: $notifications)
                Section("Approvals") {
                    Picker("Mode", selection: $approvalMode) { ForEach(ApprovalMode.allCases) { Text($0.rawValue).tag($0) } }
                    if approvalMode == .reviewer {
                        Picker("Reviewer", selection: $reviewerBotID) {
                            Text("Choose a bot").tag(nil as UUID?)
                            ForEach(store.bots.filter { $0.id != bot?.id }) { candidate in Text(candidate.name).tag(candidate.id as UUID?) }
                        }
                        Text("Escalation, timeout, reviewer errors, and reviewer approval requests fall back to asking you.").font(.caption).foregroundStyle(.secondary)
                    } else if approvalMode == .rules {
                        ForEach($approvalRules) { $rule in
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Rule name", text: $rule.name)
                                HStack { TextField("Action pattern", text: $rule.actionPattern); TextField("Command/argument pattern", text: $rule.commandPattern) }
                                HStack {
                                    Picker("Outcome", selection: $rule.outcome) { ForEach(ApprovalRuleOutcome.allCases) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden()
                                    Spacer()
                                    Button { moveRule(id: rule.id, offset: -1) } label: { Image(systemName: "arrow.up") }.disabled(approvalRules.first?.id == rule.id)
                                    Button { moveRule(id: rule.id, offset: 1) } label: { Image(systemName: "arrow.down") }.disabled(approvalRules.last?.id == rule.id)
                                    Button(role: .destructive) { approvalRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                                }
                            }.padding(.vertical, 4)
                        }
                        Button("Add rule") { approvalRules.append(.init(name: "New rule", actionPattern: "*", commandPattern: "*", outcome: .ask)) }
                        Text("First match wins. Patterns are case-insensitive and support * and ?. Allow rules accept only conservative ASCII commands and reject a short list of known-dangerous programs/options, shell syntax, quotes, escapes, newlines, and redaction markers. Broad wildcards can expose extra files. No match asks you.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                BotModelSettingsSection(cache: store.botInfo, bot: bot, conversation: $conversationModel)
                if let bot { BoxInstructionsSection(bot: bot) }
                Section("Extra instructions for this app") { TextEditor(text: $persona).frame(height: 90) }
                if bot != nil, backend == .hermes {
                    Section("Advanced") {
                        Toggle("Can manage other bots", isOn: $canManage)
                        Text("This bot may create bots, change their instructions and avatars, and retire them on its box. One per connection; \(AppConstants.name) sends it the management text only when you ask for bot management.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).padding(.horizontal, 8)
            Divider(); HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }.padding(16)
        }.frame(width: 560, height: 720).background(AppColor.panel).onAppear { if let bot { name = bot.name; title = bot.title; details = bot.botDescription; persona = bot.persona; backend = bot.backend; avatar = AvatarChoice(bot: bot); hidden = bot.isHidden; notifications = bot.notificationsEnabled; approvalMode = bot.approvalMode; approvalRules = bot.approvalRules; reviewerBotID = bot.reviewerBotID; conversationModel = bot.modelSettings?.conversation ?? .inherit; canManage = bot.canManageBots } else if AppStore.hasHermesConfiguration { backend = .hermes } }
    }
    private func setConversationModel(_ bot: Bot) {
        var settings = bot.modelSettings ?? .init(); settings.conversation = conversationModel
        bot.modelSettings = settings.isEmpty ? nil : settings
    }
    private func moveRule(id: UUID, offset: Int) { guard let index = approvalRules.firstIndex(where: { $0.id == id }) else { return }; let destination = index + offset; guard approvalRules.indices.contains(destination) else { return }; approvalRules.swapAt(index, destination) }
    private func save() { if let bot { bot.name = name; bot.title = title; bot.botDescription = details; bot.persona = persona; bot.backend = backend; if avatarTouched { avatar.apply(to: bot) }; if bot.isHidden != hidden { store.setHidden(bot, hidden) }; bot.notificationsEnabled = notifications; bot.approvalMode = approvalMode; bot.approvalRules = approvalRules; bot.reviewerBotID = reviewerBotID == bot.id ? nil : reviewerBotID; setConversationModel(bot); if bot.canManageBots != (canManage && backend == .hermes) { store.setCanManageBots(bot, canManage && backend == .hermes) }; store.save() } else { store.addBot(name: name, persona: persona, backend: backend, avatarName: nil, avatar: avatar, approvalMode: approvalMode, approvalRules: approvalRules, reviewerBotID: reviewerBotID) }; dismiss() }
}
