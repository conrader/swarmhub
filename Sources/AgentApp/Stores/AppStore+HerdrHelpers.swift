import Foundation

/// A helper open in the detail column, in place of its bot's chat: `helperID` is `HerdrClient.Helper.id`.
struct HerdrHelperSelection: Hashable, Sendable { let botID: UUID; let helperID: String }

/// A workspace read can confirm that a bot has no session, even when a cached model reading still has one.
struct HerdrAgentPresence: Equatable {
    let server: HerdrServer
    let session: HerdrClient.AgentRef?
    let isActive: Bool

    init(server: HerdrServer, agent: HerdrClient.Agent?) {
        self.server = server
        session = agent?.ref
        isActive = agent?.isStarting == true || agent?.status?.state == "working" || agent?.status?.state == "blocked"
    }
}

/// Helper agents of Herdr bots. A bot's agent starts them itself (`swarmhub-herdr helper start`, when the bot's
/// "Can start helper agents" switch told it how); the app shows them under the bot while the server lists them and
/// lets the person read one. Nothing here starts, steers or stops a helper.
extension AppStore {
    // MARK: The switch

    /// `UserDefaults`: a bot's own choice. Unset, every Herdr bot may start helpers: a helper is a sub-agent of its
    /// bot, and the server's helper settings limit what one runs on and how many an agent may have.
    static func herdrHelpersKey(_ botID: UUID) -> String { "herdrHelpers.\(botID.uuidString.lowercased())" }

    func startsHerdrHelpers(_ bot: Bot) -> Bool {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return false }
        return defaults.object(forKey: Self.herdrHelpersKey(bot.id)) as? Bool ?? true
    }

    func setStartsHerdrHelpers(_ on: Bool, for bot: Bot) { defaults.set(on, forKey: Self.herdrHelpersKey(bot.id)); objectWillChange.send() }

    // MARK: Reading them

    func hasActiveCodingAgent(_ bot: Bot) -> Bool {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return false }
        return herdrHelpers[bot.id]?.helpers.contains { $0.isLive && $0.answered != true } == true
            || herdrPresence(for: bot)?.isActive == true
    }

    func herdrTerminalSession(for bot: Bot) -> HerdrClient.AgentRef? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return nil }
        if let presence = herdrAgentPresence[bot.id] { return presence.server == herdrServer(for: bot) ? presence.session : nil }
        return herdrAgentReadings[bot.id]?.session
    }

    func herdrPresence(for bot: Bot) -> HerdrAgentPresence? {
        guard let presence = herdrAgentPresence[bot.id], presence.server == herdrServer(for: bot) else { return nil }
        return presence
    }

    func forgetHerdrAgentState(for bot: Bot) {
        herdrStreaming.remove(bot.id)
        herdrHelpers[bot.id] = nil
        herdrAgentPresence[bot.id] = nil
        herdrAgentReadings[bot.id] = nil
        herdrReadiness[bot.id] = nil
    }

    /// Every server with bots gets a discovery read, even when its chats are closed. Only a server with work gets
    /// the faster cadence. An answered helper still live is read often so its terminal disappears when it stops.
    func herdrHelperWatch() -> [String: Bool] {
        var watch: [String: Bool] = [:]
        for bot in bots where bot.backend == .herdr && !bot.isReadOnlyArchive {
            let server = herdrServer(for: bot)
            guard watch[server.id] != true else { continue }
            watch[server.id] = isAnswering(bot) || herdrReadiness[bot.id]?.isStarting == true
                || herdrPresence(for: bot)?.isActive == true || herdrHelpers[bot.id]?.helpers.contains(where: \.isLive) == true
        }
        return watch
    }

    /// Reads the watched bots' helpers until the app quits. One request per server finds each bot's agent and whether
    /// it has helpers at all; only an agent that has some costs a second one.
    func startHerdrHelperPolling(often: Duration = .seconds(3), seldom: Duration = .seconds(12)) {
        guard launchWorkEnabled, herdrHelperPoll == nil else { return }
        herdrHelperPoll = Task { [weak self] in
            let clock = ContinuousClock()
            var last: [String: ContinuousClock.Instant] = [:]
            while !Task.isCancelled, let store = self {
                let watch = store.herdrHelperWatch()
                last = last.filter { watch[$0.key] != nil }
                for (server, busy) in watch where last[server].map({ clock.now - $0 >= (busy ? often : seldom) }) ?? true {
                    guard !Task.isCancelled else { return }
                    await store.refreshHerdrHelpers(on: server)
                    last[server] = clock.now
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// How many reads of a server may fail in a row before its bots' helpers are taken off the screen.
    static let herdrHelperFailureLimit = 5

    /// Read every bot on this server from one workspace snapshot. An active turn's stream owns its helper list.
    /// A failed read keeps what it showed for a few tries, so a dropped request does not blink.
    func refreshHerdrHelpers(on serverID: String) async {
        guard let server = herdrServer(id: serverID) else { return }
        let previousPresence = herdrAgentPresence, previousHelpers = herdrHelpers
        let client = try? herdrClient(for: server)
        let workspace = try? await client?.workspace()
        guard !Task.isCancelled, herdrServer(id: serverID) == server else { return }
        let group = herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        let botIDs = Set(bots.map(\.id))
        var presence = herdrAgentPresence.filter { botIDs.contains($0.key) }
        var readiness: [UUID: HerdrAgentReadiness?] = [:]
        var helpers: [UUID: HerdrClient.Helpers?] = [:]
        var failed: [UUID] = []
        if let workspace, let client {
            let agents = group.map { bot in
                (bot, client.liveAgent(named: HerdrBackend.agentName(botName: bot.name, botID: bot.id), in: workspace))
            }
            for (bot, agent) in agents where previousPresence[bot.id] == herdrAgentPresence[bot.id] {
                presence[bot.id] = HerdrAgentPresence(server: server, agent: agent)
                readiness[bot.id] = .some(HerdrAgentReadiness(agent, in: workspace))
            }
            if presence != herdrAgentPresence { herdrAgentPresence = presence }
            noteHerdrReadiness(readiness, watched: group, on: server)

            for (bot, agent) in agents where !herdrStreaming.contains(bot.id) {
                do {
                    let list: HerdrClient.Helpers?
                    if let agent { list = try await client.helpers(of: agent, in: workspace) } else { list = nil }
                    helpers[bot.id] = .some(list?.helpers.isEmpty == false ? list : nil)
                } catch {
                    failed.append(bot.id)
                }
            }
        } else {
            failed = group.map(\.id)
        }
        guard !Task.isCancelled, herdrServer(id: serverID) == server else { return }
        if failed.isEmpty { herdrHelperFailures[serverID] = nil }
        else { herdrHelperFailures[serverID, default: 0] += 1 }
        let current = herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        let currentIDs = Set(current.map(\.id))
        if client == nil || herdrHelperFailures[serverID, default: 0] >= Self.herdrHelperFailureLimit {
            for id in failed { helpers[id] = .some(nil) }
            if workspace == nil {
                for id in failed where previousPresence[id] == herdrAgentPresence[id] {
                    presence[id] = HerdrAgentPresence(server: server, agent: nil)
                    readiness[id] = .some(nil)
                }
                if presence != herdrAgentPresence { herdrAgentPresence = presence }
                noteHerdrReadiness(readiness, watched: current, on: server)
            }
        }
        let remaining = Set(bots.map(\.id))
        var found = herdrHelpers.filter { remaining.contains($0.key) }
        // A stream can publish or a bot can move servers while a helper request is in flight.
        for (id, list) in helpers where currentIDs.contains(id) && !herdrStreaming.contains(id) && found[id] == previousHelpers[id] {
            found[id] = list
        }
        if found != herdrHelpers { herdrHelpers = found }
    }

    /// What a running turn on the event stream says beside its reply: whether the stream is delivering, and the
    /// agent's helpers whenever they change. Helpers the stream no longer lists leave the screen like polled ones.
    func herdrLive(_ note: HerdrClient.LiveNote, botID: UUID) {
        switch note {
        case .following(let on): if on { herdrStreaming.insert(botID) } else { herdrStreaming.remove(botID) }
        case .helpers(let list):
            let shown = list?.helpers.isEmpty == false ? list : nil
            if herdrHelpers[botID] != shown { herdrHelpers[botID] = shown }
        }
    }

    // MARK: Looking into one

    func isOpen(_ helper: HerdrClient.Helper, of bot: Bot) -> Bool {
        openHerdrHelper == HerdrHelperSelection(botID: bot.id, helperID: helper.id) && selectedBot?.id == bot.id && selectedGroup == nil
    }

    /// Shows the helper's read-only view in place of its bot's chat; opening the bot (or any chat) shows the chat again.
    func open(_ helper: HerdrClient.Helper, of bot: Bot) {
        open(bot)
        openHerdrHelper = HerdrHelperSelection(botID: bot.id, helperID: helper.id)
    }

    /// The helper's own session as events (`HerdrEvents.swift`): its tasks, replies, tool calls and the reply it is writing.
    func herdrHelperEvents(_ helper: HerdrClient.AgentRef, of bot: Bot) throws -> AsyncThrowingStream<HerdrEvent, Error> {
        try herdrClient(for: herdrServer(for: bot)).events(of: helper)
    }

    /// The helper's terminal as text, which the event stream does not carry; nil when Core has none any more.
    func herdrHelperScreen(_ helper: HerdrClient.AgentRef, of bot: Bot) async -> String? {
        guard let client = try? herdrClient(for: herdrServer(for: bot)) else { return nil }
        return try? await client.screen(of: helper)
    }

    /// The helper's saved task and replies, its tool calls and its terminal, read from its bot's server.
    func herdrHelperLog(_ helper: HerdrClient.AgentRef, core: String, of bot: Bot) async throws -> HerdrClient.HelperLog {
        try await herdrClient(for: herdrServer(for: bot)).helperLog(core: core, helper: helper)
    }
}
