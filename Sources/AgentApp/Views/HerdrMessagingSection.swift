import SwiftUI

/// A Herdr bot's "Other bots can message it" in the bot editor. Saved at once, like the agent's other switches; on for
/// every bot until it is turned off here (`AppStore+HerdrMessages.swift`).
struct HerdrMessagingSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        SettingSwitch(title: "Other bots can message it", detail: Self.caption(bot: bot.name, server: store.herdrServer(for: bot).name, takes: store.herdrTakesMessages(bot)),
                      symbol: "bubble.left.and.bubble.right.fill", colour: AppColor.sky, isOn: Binding(get: { store.herdrTakesMessages(bot) }, set: { store.setHerdrTakesMessages($0, for: bot) }))
        SettingSwitch(title: "Takes initiative", detail: "Run planned check-ins. The main bot can also offer help when work needs attention.",
                      symbol: "clock", colour: AppColor.sky, isOn: Binding(get: { store.takesInitiative(bot) }, set: { store.setInitiative($0, for: bot) }))
    }

    /// What the switch means, in the words of the state it is in.
    nonisolated static func caption(bot: String, server: String, takes: Bool) -> String {
        let how = "Your bots on \(server) can ask each other for help. You can read everything they say in both chats."
        return takes ? how + ""
            : "Off: other bots cannot write to \(bot). \(bot) can still write to them." + how
    }
}
