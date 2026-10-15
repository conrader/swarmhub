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
            ApprovalRouteEditor(lines: $fields.routing.lines, otherwise: $fields.routing.otherwise, excluding: bot?.id)
            Text("First match wins: this bot’s lines, then the lines for all bots (Settings → Approvals), then “Anything else”. Patterns are case-insensitive with * and ?. Approve accepts only conservative ASCII commands; unsafe, destructive or unknown commands and reviewers that don’t answer in time always come to you.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Review after") {
            ReviewAfterEditor(rules: $fields.reviewAfter, excluding: bot?.id)
            Text("The reviewer gets the reply, its steps, the code-job line and the diff stat in its “Review: <bot>” chat; the verdict appears under the reply. Reviews never hold up the reply.").font(.caption).foregroundStyle(.secondary)
        }
        BotModelSettingsSection(cache: store.botInfo, bot: bot, pendingBackend: fields.backend, conversation: $fields.conversationModel, coding: $fields.codingModel,
                                codingAgent: $fields.codingAgent)
        if let bot { BoxInstructionsSection(bot: bot); RestoreOldKeySection(bot: bot) }
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
}
