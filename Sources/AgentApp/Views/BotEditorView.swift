import SwiftUI

struct BotEditorView: View {
    @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var store: AppStore; let bot: Bot?
    @State private var name = ""; @State private var title = "Personal agent"; @State private var details = ""; @State private var persona = "You are a thoughtful, capable assistant."; @State private var backend = BackendKind.mock; @State private var avatarName = BotAvatarName.faceCoral
    @State private var hidden = false; @State private var notifications = true
    @State private var approvalMode = ApprovalMode.ask; @State private var approvalRules = ApprovalRule.sensibleDefaults; @State private var reviewerBotID: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(bot == nil ? "New agent" : "Agent settings").font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain) }.padding(20)
            Divider(); Form {
                Picker("Avatar", selection: $avatarName) { Section("Flat bot faces") { ForEach(BotAvatarName.allCases.filter(\.isFlatFace)) { avatar in HStack { AvatarImage(name: avatar).scaledToFill().frame(width: 24, height: 24).clipShape(Circle()); Text(avatar.displayName) }.tag(avatar) } }; Section("Clay collection") { ForEach(BotAvatarName.allCases.filter { !$0.isFlatFace }) { avatar in HStack { AvatarImage(name: avatar).scaledToFill().frame(width: 24, height: 24).clipShape(Circle()); Text(avatar.displayName) }.tag(avatar) } } }
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
                        Text("First match wins. Patterns are case-insensitive and support * and ?. Allow rules never cross shell separators, substitutions, redirects, or newlines; those always ask you. No match asks you.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Instructions") { TextEditor(text: $persona).frame(height: 90) }
            }.formStyle(.grouped).padding(.horizontal, 8)
            Divider(); HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }.padding(16)
        }.frame(width: 560, height: 720).background(AppColor.panel).onAppear { if let bot { name = bot.name; title = bot.title; details = bot.botDescription; persona = bot.persona; backend = bot.backend; avatarName = bot.avatarName; hidden = bot.isHidden; notifications = bot.notificationsEnabled; approvalMode = bot.approvalMode; approvalRules = bot.approvalRules; reviewerBotID = bot.reviewerBotID } else if AppStore.hasHermesConfiguration { backend = .hermes } }
    }
    private func moveRule(id: UUID, offset: Int) { guard let index = approvalRules.firstIndex(where: { $0.id == id }) else { return }; let destination = index + offset; guard approvalRules.indices.contains(destination) else { return }; approvalRules.swapAt(index, destination) }
    private func save() { if let bot { bot.name = name; bot.title = title; bot.botDescription = details; bot.persona = persona; bot.backend = backend; bot.avatarName = avatarName; bot.isHidden = hidden; bot.notificationsEnabled = notifications; bot.approvalMode = approvalMode; bot.approvalRules = approvalRules; bot.reviewerBotID = reviewerBotID == bot.id ? nil : reviewerBotID; store.save() } else { store.addBot(name: name, persona: persona, backend: backend, avatarName: avatarName, approvalMode: approvalMode, approvalRules: approvalRules, reviewerBotID: reviewerBotID) }; dismiss() }
}
