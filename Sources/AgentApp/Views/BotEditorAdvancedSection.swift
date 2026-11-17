import SwiftUI

/// The editor's Advanced part: Title and Description, Show in sidebar, and for a Herdr bot its agent (server, agent
/// program, model, steer), the main-bot role, helper agents and the projects on other servers it may use.
struct BotEditorAdvancedSection: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot?
    @Binding var fields: BotEditorFields

    var body: some View {
        VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                StandaloneField(title: "Title", text: $fields.title, note: "A few words under the name, such as what this bot is for.")
                StandaloneField(title: "Description", text: $fields.details, lines: 2...4)
            }
            SettingSwitch(title: "Show in sidebar", detail: "Off: the bot is kept, and listed under Hidden chats.", symbol: "sidebar.left", colour: .gray, isOn: Binding(get: { !fields.hidden }, set: { fields.hidden = !$0 }))
            if let bot, fields.backend == .herdr {
                HerdrBotSection(bot: bot)
                let server = store.herdrServer(for: bot), main = store.herdrMainBot(on: server)
                VStack(alignment: .leading, spacing: 14) {
                    SettingSwitch(title: "Main bot of \(server.name)", detail: Self.mainBotCaption(bot: bot.name, isMain: fields.canManage, main: main?.id == bot.id ? nil : main?.name, server: server.name),
                                  symbol: "star.fill", colour: .orange, isOn: $fields.canManage)
                    if fields.canManage {
                        // Saved at once, like the agent's other switches.
                        SettingSwitch(title: "Ask me before creating bots", detail: "Nothing is created before you press Create.", symbol: "hand.raised.fill", colour: .blue,
                                      isOn: Binding(get: { store.herdrAsksFirst(bot) }, set: { store.setHerdrAsksFirst($0, for: bot) }))
                    }
                }
                HerdrMessagingSection(bot: bot)
                // Saved at once, like the agent's other switches; on for every Herdr bot until it is turned off here.
                SettingSwitch(title: "Can start helper agents",
                              detail: "Helpers are sub-agents of this bot: its agent is told how to hand parts of its work to them on \(server.name), and to say how hard each task is: easy, medium or hard. The server's helper settings decide which model each difficulty runs on and how many helpers one agent may have; the agent cannot choose a model. Helpers show under the bot in the sidebar while they run. A running agent learns this with your next message; turning it off applies when the bot next starts a fresh agent.",
                              symbol: "person.2.fill", colour: .green, isOn: Binding(get: { store.startsHerdrHelpers(bot) }, set: { store.setStartsHerdrHelpers($0, for: bot) }))
                // Saved at once too: which projects on other servers this bot may use.
                HerdrBotProjectsSection(bot: bot)
            }
        }
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
}
