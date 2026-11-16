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
        if let bot, fields.backend == .herdr {
            let server = store.herdrServer(for: bot), main = store.herdrMainBot(on: server)
            Section("Main bot") {
                Toggle("Main bot of \(server.name)", isOn: $fields.canManage)
                if fields.canManage {
                    // Saved at once, like the agent's other switches.
                    Toggle("Ask me before creating bots", isOn: Binding(get: { store.herdrAsksFirst(bot) }, set: { store.setHerdrAsksFirst($0, for: bot) }))
                }
                Text(Self.mainBotCaption(bot: bot.name, isMain: fields.canManage, main: main?.id == bot.id ? nil : main?.name, server: server.name)).font(.caption).foregroundStyle(.secondary)
            }
            Section("Helper agents") {
                // Saved at once, like the agent's other switches; on for every Herdr bot until it is turned off here.
                Toggle("Can start helper agents", isOn: Binding(get: { store.startsHerdrHelpers(bot) }, set: { store.setStartsHerdrHelpers($0, for: bot) }))
                Text("Helpers are sub-agents of this bot: its agent is told how to hand parts of its work to them on \(server.name), and to say how hard each task is: easy, medium or hard. The server's helper settings decide which model each difficulty runs on and how many helpers one agent may have; the agent cannot choose a model. Helpers show under the bot in the sidebar while they run. A running agent learns this with your next message; turning it off applies when the bot next starts a fresh agent.").font(.caption).foregroundStyle(.secondary)
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

    /// What the Main bot section says: what the role is, who holds it now, and what turning it on here changes.
    nonisolated static func mainBotCaption(bot: String, isMain: Bool, main other: String?, server: String) -> String {
        if isMain {
            return "Each server has one main bot, and only it creates bots. \(bot) decides itself whether to create a bot, ask you, or refuse; a bot it creates is added at once and shown above its chat’s message box, where you can remove or keep it. Other bots ask \(bot) when they want a new bot, and are told the outcome. With “Ask me before creating bots” on, nothing is created before you press Create."
                + (other.map { " Saving takes the role from \($0)." } ?? "")
        }
        return "Each server has one main bot, and only it creates bots. " + (other.map { "On \(server) that is \($0): when \(bot) wants a new bot it asks \($0), who creates it, asks you, or refuses." }
            ?? "\(server) has none yet, so no bot there can create bots: turn this on for the bot that should decide.")
    }

    /// The older backends' sections: never for a Herdr bot, and for the others only while `LegacySurface` is shown.
    private var showsBox: Bool { legacy && fields.backend != .herdr }

    private func place(_ bot: Bot) -> String {
        BoxAddress.url(bot.hermesBaseURL ?? store.defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL).map(BoxAddress.place) ?? SetupCopy.thisMac
    }
}
