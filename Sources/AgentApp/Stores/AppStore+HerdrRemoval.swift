import Foundation

/// The agent of a bot that was removed: which server it runs on and what the server calls it. Kept until the server
/// has been asked to end it, so a server that could not be reached then is asked again later.
struct HerdrAgentEnding: Codable, Equatable, Sendable {
    var server: String
    var agent: String
    /// The bot's name, for a person reading the saved list.
    var bot: String
}

/// What the person reads before a bot is removed.
enum BotRemovalCopy {
    static func title(_ name: String) -> String { "Delete \(name)?" }

    /// `server`: where the bot's agent runs; nil for a bot that has none there (a sample, an archive).
    static func message(server: String?) -> String {
        guard let server else { return "Its chat is removed from this Mac. This can’t be undone." }
        return "Its chat is removed from this Mac, and its agent on \(server) is ended, with what that agent remembers. This can’t be undone."
    }
}

/// Removing a bot ends its agent. A Herdr bot is this app's record plus an agent program running on its server;
/// deleting the record used to leave that program running there, unseen, until the server's own limit.
/// Only that bot's agent is ended: the one the server lists under the bot's own name (`HerdrBackend.agentName`,
/// which ends in the start of the bot's id), found the way a message finds it. Its helpers, other bots' agents and
/// anything started outside the app are left alone. A server that cannot be reached is tolerated: the bot is removed
/// all the same, and its agent is ended the next time the app starts or another bot is removed.
extension AppStore {
    /// `UserDefaults`: the agents still to end, as JSON, newest last.
    static let herdrEndingsKey = "herdrAgentsToEnd", herdrEndingsKept = 40

    /// What removing `bot` ends on its server; nil for a bot that has no agent there.
    func herdrEnding(for bot: Bot) -> HerdrAgentEnding? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive, !bot.isDemo else { return nil }
        return HerdrAgentEnding(server: herdrServer(for: bot).id, agent: HerdrBackend.agentName(botName: bot.name, botID: bot.id), bot: bot.name)
    }

    /// The name of the server `bot`'s agent runs on, for the confirmation; nil when removing it ends nothing there.
    func herdrEndingPlace(for bot: Bot) -> String? { herdrEnding(for: bot).flatMap { herdrServer(id: $0.server)?.name } }

    var herdrEndings: [HerdrAgentEnding] {
        defaults.data(forKey: Self.herdrEndingsKey).flatMap { try? JSONDecoder().decode([HerdrAgentEnding].self, from: $0) } ?? []
    }

    private func setHerdrEndings(_ endings: [HerdrAgentEnding]) {
        if endings.isEmpty { defaults.removeObject(forKey: Self.herdrEndingsKey) }
        else { defaults.set(try? JSONEncoder().encode(Array(endings.suffix(Self.herdrEndingsKept))), forKey: Self.herdrEndingsKey) }
    }

    enum HerdrEnded: Equatable, Sendable {
        /// The server ended it.
        case ended
        /// The server lists no running agent of that bot, or the server itself is no longer one of the app's.
        case nothingToEnd
        /// The server did not answer, or refused: asked again later.
        case unreachable
    }

    /// Asks the server once to end the agent of a removed bot.
    func endHerdrAgent(_ ending: HerdrAgentEnding) async -> HerdrEnded {
        guard let server = herdrServer(id: ending.server) else { return .nothingToEnd }
        do {
            let client = try herdrClient(for: server)
            guard let agent = client.liveAgent(named: ending.agent, in: try await client.workspace()) else { return .nothingToEnd }
            try await client.end(agent)
            return .ended
        } catch { return .unreachable }
    }

    /// `bot` is being removed: its turn stops here, and its agent is noted for ending before the record goes, because
    /// the server and the name are read from the bot's own settings. `delete` calls `herdrAgentRemoved` with it.
    func herdrEndingBeforeRemoval(of bot: Bot) -> (ending: HerdrAgentEnding, warming: Task<Void, Never>?)? {
        guard launchWorkEnabled, let ending = herdrEnding(for: bot) else { return nil }
        turn(in: bot)?.task?.cancel()
        setHerdrEndings(herdrEndings.filter { $0 != ending } + [ending])
        return (ending, herdrWarming[bot.id])
    }

    /// Ends the removed bot's agent, in the background. A start ahead of time that is on its way is let through
    /// first, so the agent it starts is the one that is ended.
    @discardableResult func herdrAgentRemoved(_ removal: (ending: HerdrAgentEnding, warming: Task<Void, Never>?), botID: UUID) -> Task<Void, Never> {
        herdrReadiness[botID] = nil; herdrAgentReadings[botID] = nil; herdrHelpers[botID] = nil
        return Task { [weak self] in
            await removal.warming?.value
            await self?.settleHerdrEndings()
        }
    }

    /// Asks each server to end the agents of removed bots that are still noted, and forgets those it answered for.
    func settleHerdrEndings() async {
        for ending in herdrEndings where await endHerdrAgent(ending) != .unreachable {
            setHerdrEndings(herdrEndings.filter { $0 != ending })
        }
    }
}
