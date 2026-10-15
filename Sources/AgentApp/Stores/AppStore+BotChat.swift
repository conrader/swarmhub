import Foundation

/// P46 1: a Hermes bot's main SwarmHub session is titled "Bot Chat", the session Hermes's `deliver: bot-chat:<profile>`
/// routines hand their output to. Titled once per session (on connect, and before a heartbeat is set up), and only while no
/// other session of that profile holds the title: then SwarmHub asks ("Use this chat"). Threads keep their titles, and
/// SwarmHub keeps showing its own bot name.
enum BotChatCopy {
    static let earlierTitle = "Bot Chat (earlier)"
    static func noSession(_ name: String) -> String { "\(name) has no main chat on the box yet: send it a message first." }
    static func conflict(_ name: String, profile: String) -> String {
        "Another chat of \(profile) is already titled \"Bot Chat\", so routines and the heartbeat would answer there, not in \(name)'s chat here. Settings → Advanced → Heartbeat → Use this chat."
    }
    static func failed(_ reason: String) -> String { "Could not title this chat \"Bot Chat\": \(reason)" }
}

extension AppStore {
    /// True when the bot's current main session already carries the title (as far as SwarmHub set or saw it).
    func hasBotChat(_ bot: Bot) -> Bool { bot.hermesSessionID != nil && heartbeatSettings.botChats[bot.id.uuidString] == bot.hermesSessionID }

    /// The other session holding the title, when SwarmHub had to ask.
    func botChatConflict(_ bot: Bot) -> String? { heartbeatSettings.conflicts[bot.id.uuidString] }

    /// Titles the bot's main session "Bot Chat" unless it is already, or another session of the profile is (then the
    /// conflict is kept and a line asks once). nil when the chat is the Bot Chat; else why not.
    @discardableResult func ensureBotChat(_ bot: Bot) async -> String? {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive, let session = bot.hermesSessionID else { return BotChatCopy.noSession(bot.name) }
        if hasBotChat(bot) { return nil }
        let key = bot.id.uuidString
        guard !needsKey(bot), let backend = try? backend(for: bot) as? HermesBackend else { return BotChatCopy.failed("this bot has no readable key.") }
        do {
            // Every source (a `hermes chat -c "Bot Chat"` session is a CLI one), plus SwarmHub's own list for the main row.
            let rows = try await backend.sessionListing(source: nil, limit: 200) + backend.sessionListing(source: "api_server")
            guard bot.hermesSessionID == session else { return nil }
            if let other = rows.first(where: { $0.id != session && $0.title == HeartbeatPlan.botChatTitle }) {
                let known = heartbeatSettings.conflicts[key] == other.id
                heartbeatSettings.conflicts[key] = other.id; save()
                let line = BotChatCopy.conflict(bot.name, profile: profile(of: bot))
                if !known { bot.messages.append(ChatMessage(role: .system, content: line, metadata: [TurnKey.tone: "warning"])); objectWillChange.send(); save() }
                return line
            }
            if !rows.contains(where: { $0.id == session && $0.title == HeartbeatPlan.botChatTitle }) {
                try await backend.setSessionTitle(session, title: HeartbeatPlan.botChatTitle)
            }
            heartbeatSettings.botChats[key] = session; heartbeatSettings.conflicts[key] = nil; save()
            return nil
        } catch {
            return BotChatCopy.failed(BotInfoCache.describe(error, key: backend.apiKey))
        }
    }

    /// "Use this chat": the other session becomes "Bot Chat (earlier)", then this chat takes the title.
    @discardableResult func useThisChatAsBotChat(_ bot: Bot) async -> String? {
        guard let other = botChatConflict(bot) else { return await ensureBotChat(bot) }
        guard let backend = try? backend(for: bot) as? HermesBackend else { return BotChatCopy.failed("this bot has no readable key.") }
        do { try await backend.setSessionTitle(other, title: BotChatCopy.earlierTitle) }
        catch { return BotChatCopy.failed(BotInfoCache.describe(error, key: backend.apiKey)) }
        heartbeatSettings.conflicts[bot.id.uuidString] = nil; save()
        return await ensureBotChat(bot)
    }
}
