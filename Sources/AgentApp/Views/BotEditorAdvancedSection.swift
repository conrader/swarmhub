import SwiftUI

/// The editor's Advanced part: the bot's role in a few words, and for a Herdr bot the main-bot role, whether other
/// bots may write to it, helpers and the projects on other servers it may use. What it runs on (AI and model) has
/// one home, the Model tab of its Details; showing or hiding it is in its sidebar menu.
struct BotEditorAdvancedSection: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot?
    @Binding var fields: BotEditorFields
    /// The bot had a description when its settings opened, so the field stays while it is being cleared.
    @State private var hadDescription = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                StandaloneField(title: "Role", text: $fields.title, prompt: "Optional, such as “Research” or “Chief of staff”")
                // A description written before (or imported) stays editable; a bot without one is not asked for it.
                if !fields.details.isEmpty || hadDescription { StandaloneField(title: "Description", text: $fields.details, lines: 2...4) }
            }
            if let bot, fields.backend == .herdr {
                let server = store.herdrServer(for: bot), main = store.herdrMainBot(on: server)
                VStack(alignment: .leading, spacing: 14) {
                    SettingSwitch(title: "Main bot", detail: Self.mainBotCaption(bot: bot.name, isMain: fields.canManage, main: main?.id == bot.id ? nil : main?.name, server: server.name),
                                  symbol: "star.fill", colour: AppColor.clay, isOn: $fields.canManage)
                    if fields.canManage {
                        // Saved at once, like the agent's other switches.
                        SettingSwitch(title: "Ask me before creating bots", detail: "Off: \(bot.name) may create a bot it is sure you want, and shows it to you to keep or remove.", symbol: "hand.raised.fill", colour: AppColor.sky,
                                      isOn: Binding(get: { store.herdrAsksFirst(bot) }, set: { store.setHerdrAsksFirst($0, for: bot) }))
                    }
                }.disabled(bot.isReadOnlyArchive || bot.isDemo)
                HerdrMessagingSection(bot: bot)
                // Saved at once, like the agent's other switches; on for every Herdr bot until it is turned off here.
                SettingSwitch(title: "Can use helpers",
                              detail: "\(bot.name) may hand parts of its work to helpers. They show under it in the sidebar while they run. What helpers run on is set in \(SettingsLayout.path(.servers, HerdrSettingsSection.Part.helpers.rawValue)).",
                              symbol: "person.2.fill", colour: AppColor.sage, isOn: Binding(get: { store.startsHerdrHelpers(bot) }, set: { store.setStartsHerdrHelpers($0, for: bot) }))
                // Saved at once too: which projects on other servers this bot may use.
                HerdrBotProjectsSection(bot: bot)
            }
        }.onAppear { hadDescription = !fields.details.isEmpty }
    }

    /// What the Main bot section says: what the role is, who holds it now, and what turning it on here changes.
    nonisolated static func mainBotCaption(bot: String, isMain: Bool, main other: String?, server: String) -> String {
        if isMain {
            return "\(bot) can set up other bots for you, and your other bots ask it when they want one." + (other.map { " Saving takes this role from \($0)." } ?? "")
        }
        return other.map { "\($0) is the main bot on \(server): the one that sets up other bots. Turn this on to give \(bot) that role instead." }
            ?? "\(server) has no main bot yet, so no bot there can set up other bots. Turn this on for the bot that should."
    }
}
