import SwiftUI

/// A Herdr bot's "Other bots can message it" in the bot editor. Saved at once, like the agent's other switches; on for
/// every bot until it is turned off here (`AppStore+HerdrMessages.swift`).
struct HerdrMessagingSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        Section("Messages between bots") {
            Toggle("Other bots can message it", isOn: Binding(get: { store.herdrTakesMessages(bot) }, set: { store.setHerdrTakesMessages($0, for: bot) }))
            Text(Self.caption(bot: bot.name, server: store.herdrServer(for: bot).name, takes: store.herdrTakesMessages(bot))).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// What the switch means, in the words of the state it is in.
    nonisolated static func caption(bot: String, server: String, takes: Bool) -> String {
        let how = "The bots on \(server) can write to each other by name. A message appears in the other bot’s chat, marked as passed on, and the answer comes back into the sender’s chat, so you can read everything they say in both chats. Stop a bot to end an exchange."
        return takes ? how + " \(bot) can still write to other bots when this is off."
            : "Off: a bot that writes to \(bot) is told that \(bot) takes no messages. \(bot) can still write to other bots, and their answers still reach it. " + how
    }
}
