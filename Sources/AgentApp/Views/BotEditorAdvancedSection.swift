import SwiftUI

/// The editor's Advanced part (P21 item 7), unchanged controls moved out of the simple part: Title and Description,
/// Backend (the only place "Mock" is offered), Show in sidebar, Approvals, the Models section (P13/P17 edit it here),
/// box instructions, bot management, SwarmHub skills (P27), and a read-only "Runs on <where> as <name>" for an agent bound to a box.
struct BotEditorAdvancedSection: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot?
    @Binding var fields: BotEditorFields

    var body: some View {
        Section {
            TextField("Title", text: $fields.title); TextField("Description", text: $fields.details, axis: .vertical).lineLimit(2...4)
            Picker("Backend", selection: Binding(get: { fields.backend }, set: { fields.backend = $0; fields.conversationModel = .inherit; fields.codingModel = .inherit })) { ForEach(BackendKind.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Show in sidebar", isOn: Binding(get: { !fields.hidden }, set: { fields.hidden = !$0 }))
            if let bot, bot.backend == .hermes, let profile = bot.hermesProfile ?? (bot.isGrokHistoryOnly ? nil : "default") {
                Text(SimpleCopy.runsOn(place(bot), as: profile)).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Approvals") {
            Picker("Mode", selection: $fields.approvalMode) { ForEach(ApprovalMode.allCases) { Text($0.rawValue).tag($0) } }
            if fields.approvalMode == .reviewer {
                Picker("Reviewer", selection: $fields.reviewerBotID) {
                    Text("Choose a bot").tag(nil as UUID?)
                    ForEach(store.bots.filter { $0.id != bot?.id }) { candidate in Text(candidate.name).tag(candidate.id as UUID?) }
                }
                Text("Escalation, timeout, reviewer errors, and reviewer approval requests fall back to asking you.").font(.caption).foregroundStyle(.secondary)
            } else if fields.approvalMode == .rules {
                ForEach($fields.approvalRules) { $rule in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Rule name", text: $rule.name)
                        HStack { TextField("Action pattern", text: $rule.actionPattern); TextField("Command/argument pattern", text: $rule.commandPattern) }
                        HStack {
                            Picker("Outcome", selection: $rule.outcome) { ForEach(ApprovalRuleOutcome.allCases) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden()
                            Spacer()
                            Button { moveRule(id: rule.id, offset: -1) } label: { Image(systemName: "arrow.up") }.disabled(fields.approvalRules.first?.id == rule.id)
                            Button { moveRule(id: rule.id, offset: 1) } label: { Image(systemName: "arrow.down") }.disabled(fields.approvalRules.last?.id == rule.id)
                            Button(role: .destructive) { fields.approvalRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                        }
                    }.padding(.vertical, 4)
                }
                Button("Add rule") { fields.approvalRules.append(.init(name: "New rule", actionPattern: "*", commandPattern: "*", outcome: .ask)) }
                Text("First match wins. Patterns are case-insensitive and support * and ?. Allow rules accept only conservative ASCII commands and reject a short list of known-dangerous programs/options, shell syntax, quotes, escapes, newlines, and redaction markers. Broad wildcards can expose extra files. No match asks you.").font(.caption).foregroundStyle(.secondary)
            }
        }
        BotModelSettingsSection(cache: store.botInfo, bot: bot, pendingBackend: fields.backend, conversation: $fields.conversationModel, coding: $fields.codingModel,
                                codingAgent: $fields.codingAgent)
        if let bot { BoxInstructionsSection(bot: bot) }
        if bot != nil, fields.backend == .hermes || fields.backend == .openClaw {
            Section("Bot management") {
                Toggle("Can manage other bots", isOn: $fields.canManage)
                Text(fields.backend == .openClaw
                     ? "This agent may create agents, change their instructions and avatars, and retire them on its Gateway host (its host must allow exec). One per Gateway; \(AppConstants.name) sends it the management text only when you ask for bot management."
                     : "This bot may create bots, change their instructions and avatars, and retire them on its box. One per connection; \(AppConstants.name) sends it the management text only when you ask for bot management.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let bot { SwarmHubSkillsSection(bot: bot) }
    }

    private func place(_ bot: Bot) -> String {
        BoxAddress.url(bot.hermesBaseURL ?? store.defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL).map(BoxAddress.place) ?? SetupCopy.thisMac
    }

    private func moveRule(id: UUID, offset: Int) {
        guard let index = fields.approvalRules.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard fields.approvalRules.indices.contains(destination) else { return }
        fields.approvalRules.swapAt(index, destination)
    }
}
