import SwiftUI

/// The editor's Advanced part (P21 item 7), unchanged controls moved out of the simple part: Title and Description,
/// Backend (the only place "Mock" is offered), Show in sidebar, Approvals, the Models section (P13/P17 edit it here),
/// box instructions, bot management, SwarmHub skills (P27), and a read-only "Runs on <where> as <name>" for an agent bound to a box.
struct BotEditorAdvancedSection: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot?
    @Binding var fields: BotEditorFields
    /// Off (the default): the Backend picker and the sections of the older backends stay out of sight (`LegacySurface`).
    @AppStorage(LegacySurface.key) private var legacy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section {
            TextField("Title", text: $fields.title); TextField("Description", text: $fields.details, axis: .vertical).lineLimit(2...4)
            if legacy {
                Picker("Backend", selection: Binding(get: { fields.backend }, set: { fields.backend = $0; fields.conversationModel = .inherit; fields.codingModel = .inherit })) { ForEach(BackendKind.allCases) { Text($0.rawValue).tag($0) } }
            }
            Toggle("Show in sidebar", isOn: Binding(get: { !fields.hidden }, set: { fields.hidden = !$0 }))
            if let bot, bot.backend == .hermes, let profile = bot.hermesProfile ?? (bot.isGrokHistoryOnly ? nil : "default") {
                Text(SimpleCopy.runsOn(place(bot), as: profile)).font(.caption).foregroundStyle(.secondary)
            }
        }
        // A Herdr agent asks in its own terminal; SwarmHub routes none of its approvals. The sections that serve a bot
        // of the older backends (approvals, models, box instructions, management, skills) show only with those backends.
        if showsBox {
            Section("Approvals") {
                ApprovalRouteEditor(lines: $fields.routing.lines, otherwise: $fields.routing.otherwise, excluding: bot?.id)
                Text("First match wins: this bot’s lines, then the lines for all bots (Settings → Approvals), then “Anything else”. Patterns are case-insensitive with * and ?. Approve accepts only conservative ASCII commands; unsafe, destructive or unknown commands and reviewers that don’t answer in time always come to you.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Review after") {
            ReviewAfterEditor(rules: $fields.reviewAfter, excluding: bot?.id)
            Text("The reviewer gets the reply, its steps, the code-job line and the diff stat in its “Review: <bot>” chat; the verdict appears under the reply. Reviews never hold up the reply.").font(.caption).foregroundStyle(.secondary)
        }
        if showsBox {
            BotModelSettingsSection(cache: store.botInfo, bot: bot, pendingBackend: fields.backend, conversation: $fields.conversationModel, coding: $fields.codingModel,
                                    codingAgent: $fields.codingAgent)
        }
        if let bot, showsBox { BoxInstructionsSection(bot: bot); RestoreOldKeySection(bot: bot) }
        if let bot, fields.backend == .herdr { HerdrBotSection(bot: bot) }
        if bot != nil, fields.backend == .herdr {
            Section("Bot management") {
                Toggle("Can create other bots", isOn: $fields.canManage)
                Text("Ask this bot for a new bot and it proposes one: a name, an avatar and instructions. \(AppConstants.name) shows you the proposal in the chat and adds the bot, on the same Herdr server, only when you press Create. One per server. A running agent learns this when you next ask it for a bot.").font(.caption).foregroundStyle(.secondary)
            }
            if let bot {
                Section("Helper agents") {
                    // Saved at once, like the agent's other switches; until it is set it follows "Can create other bots".
                    Toggle("Can start helper agents", isOn: Binding(get: { store.startsHerdrHelpers(bot, managing: fields.canManage) }, set: { store.setStartsHerdrHelpers($0, for: bot) }))
                    Text("This bot's agent is told how to hand parts of its work to helper agents on \(store.herdrServer(for: bot).name), and to say how hard each task is: easy, medium or hard. The server's helper settings decide which model each difficulty runs on and how many helpers one agent may have; the agent cannot choose a model. Helpers show under the bot in the sidebar while they run. A running agent learns this with your next message; turning it off applies when the bot next starts a fresh agent.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        // A bot still on an older backend: one press moves it, keeping its name, avatar, instructions and chat.
        if let bot, !legacy, bot.backend == .hermes || bot.backend == .openClaw, !bot.isReadOnlyArchive {
            Section("Herdr") {
                Button("Move this bot to Herdr") { store.moveToHerdr(bot); store.objectWillChange.send(); store.save(); dismiss() }
                Text("It keeps its name, avatar, instructions and chat history, and starts an agent on \(store.herdrServers[0].name) with its next message. What lives on its old server (memory, skills, routines, connected apps) does not move.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if bot != nil, showsBox, fields.backend == .hermes || fields.backend == .openClaw {
            Section("Bot management") {
                Toggle("Can manage other bots", isOn: $fields.canManage)
                Text(fields.backend == .openClaw
                     ? "This agent may create agents, change their instructions and avatars, and retire them on its Gateway host (its host must allow exec). One per Gateway; \(AppConstants.name) sends it the management text only when you ask for bot management."
                     : "This bot may create bots, change their instructions and avatars, and retire them on its box. One per connection; \(AppConstants.name) sends it the management text only when you ask for bot management.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let bot, showsBox { SwarmHubSkillsSection(bot: bot) }
    }

    /// The older backends' sections: never for a Herdr bot, and for the others only while `LegacySurface` is shown.
    private var showsBox: Bool { legacy && fields.backend != .herdr }

    private func place(_ bot: Bot) -> String {
        BoxAddress.url(bot.hermesBaseURL ?? store.defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL).map(BoxAddress.place) ?? SetupCopy.thisMac
    }
}
