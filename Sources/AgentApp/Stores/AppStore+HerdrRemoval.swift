import Foundation

/// The runtime names to end on a removed bot's server. Kept until the server confirms they are gone.
struct HerdrAgentEnding: Codable, Hashable, Sendable {
    var server: String
    var agent: String?
    /// The bot's name, for a person reading the saved list.
    var bot: String
    var groupAgents: [String]? = nil
}

/// What the person reads before a bot is removed.
enum BotRemovalCopy {
    static func title(_ name: String) -> String { "Delete \(name)?" }

    /// `server`: where the bot's agent runs; nil for a bot that has none there (a sample, an archive).
    static func message(server: String?) -> String {
        guard let server else { return "Its chat is removed from this Mac. This can’t be undone." }
        return "Its chat is removed from this Mac. Its agent on \(server) and its agents in group chats are ended, with what they remember. This can’t be undone."
    }
}

/// Removing a bot ends its agent. A Herdr bot is this app's record plus an agent program running on its server;
/// deleting the record used to leave that program running there, unseen, until the server's own limit.
/// The bot's direct and group agents are ended by their runtime names. If the server cannot be reached, the app
/// tries again the next time it starts or another bot is removed.
extension AppStore {
    /// Earlier versions kept outstanding direct agents in `UserDefaults`.
    static let herdrEndingsKey = "herdrAgentsToEnd"

    /// What removing `bot` ends on its server; nil for a bot that has no agent there.
    func herdrEnding(for bot: Bot) -> HerdrAgentEnding? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive, !bot.isDemo else { return nil }
        return HerdrAgentEnding(server: herdrServer(for: bot).id, agent: HerdrBackend.agentName(botName: bot.name, botID: bot.id), bot: bot.name)
    }

    /// The name of the server `bot`'s agent runs on, for the confirmation; nil when removing it ends nothing there.
    func herdrEndingPlace(for bot: Bot) -> String? { herdrEnding(for: bot).flatMap { herdrServer(id: $0.server)?.name } }

    var herdrEndings: [HerdrAgentEnding] {
        pendingHerdrEndings + legacyHerdrEndings.filter { !pendingHerdrEndings.contains($0) }
    }

    private var legacyHerdrEndings: [HerdrAgentEnding] {
        defaults.data(forKey: Self.herdrEndingsKey).flatMap { try? JSONDecoder().decode([HerdrAgentEnding].self, from: $0) } ?? []
    }

    private func setLegacyHerdrEndings(_ endings: [HerdrAgentEnding]) {
        if endings.isEmpty { defaults.removeObject(forKey: Self.herdrEndingsKey) }
        else { defaults.set(try? JSONEncoder().encode(endings), forKey: Self.herdrEndingsKey) }
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
            let workspace = try await client.workspace()
            let groupNames = Set(ending.groupAgents ?? [])
            var agents = workspace.agents.filter { $0.isLive && $0.parent == nil && groupNames.contains($0.name) }
            if let name = ending.agent, let direct = client.liveAgent(named: name, in: workspace) { agents.append(direct) }
            guard !agents.isEmpty else { return .nothingToEnd }
            for agent in agents {
                do { try await client.end(agent) }
                catch HerdrClient.Failure.http(404, _) { /* It has already ended. */ }
            }
            return .ended
        } catch { return .unreachable }
    }

    /// Group runtime names are stable even when the bot leaves the group or moves to another server.
    func herdrEndingsForRemoval(of bot: Bot) -> [HerdrAgentEnding] {
        guard launchWorkEnabled, var ending = herdrEnding(for: bot) else { return [] }
        let groupNames = (groups.map(\.id) + deletedGroupIDs).compactMap { groupID in
            HerdrBackend.groupRuntimeName(sessionID: sessionNamespace + GroupRouting.sessionID(group: groupID, bot: bot.id), botID: bot.id)
        }
        guard !groupNames.isEmpty else { return [ending] }
        ending.groupAgents = groupNames
        return [ending] + herdrServers.filter { $0.id != ending.server }.map {
            HerdrAgentEnding(server: $0.id, agent: nil, bot: bot.name, groupAgents: groupNames)
        }
    }

    /// Cancel this bot's turns and let any warm start finish before asking the server to end its agents.
    func herdrAgentRemoved(_ bot: Bot, endings: [HerdrAgentEnding]) {
        busyHerdrEndings.formUnion(endings)
        let warming = herdrWarming[bot.id]
        let tasks = runningTurns.values.filter { $0.botID == bot.id }.compactMap(\.task)
        tasks.forEach { $0.cancel() }
        forgetHerdrAgentState(for: bot)
        Task { [weak self] in
            await warming?.value
            for task in tasks { await task.value }
            guard let self else { return }
            self.busyHerdrEndings.subtract(endings)
            await self.settleHerdrEndings()
        }
    }

    /// Asks each server to end the agents of removed bots that are still noted, and forgets those it answered for.
    func settleHerdrEndings() async {
        for ending in herdrEndings where busyHerdrEndings.insert(ending).inserted {
            let outcome = await endHerdrAgent(ending)
            busyHerdrEndings.remove(ending)
            guard outcome != .unreachable else { continue }
            if let index = pendingHerdrEndings.firstIndex(of: ending) {
                pendingHerdrEndings.remove(at: index)
                save()
                if turns.saveFailing { pendingHerdrEndings.insert(ending, at: index) }
            }
            let legacy = legacyHerdrEndings
            if legacy.contains(ending) { setLegacyHerdrEndings(legacy.filter { $0 != ending }) }
        }
    }
}
