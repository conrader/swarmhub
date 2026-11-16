import Foundation

/// A helper open in the detail column, in place of its bot's chat: `helperID` is `HerdrClient.Helper.id`.
struct HerdrHelperSelection: Hashable, Sendable { let botID: UUID; let helperID: String }

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

    /// The Herdr bots whose helpers are worth reading now, and whether often: a bot that is answering or has helpers
    /// listed is read every few seconds, the open chat of an idle bot only now and then (an agent starts helpers
    /// while it works, so an idle one rarely has news). Every other bot is not read at all.
    func herdrHelperWatch() -> (bots: [Bot], often: Bool) {
        let open = selectedGroup == nil && !showingReports ? selectedBot?.id : nil
        var often = false
        let watched = bots.filter { bot in
            guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return false }
            let busy = isWorking(bot) || herdrHelpers[bot.id]?.helpers.isEmpty == false
            if busy { often = true }
            return busy || bot.id == open
        }
        return (watched, often)
    }

    /// Reads the watched bots' helpers until the app quits. One request per server finds each bot's agent and whether
    /// it has helpers at all; only an agent that has some costs a second one.
    func startHerdrHelperPolling(often: Duration = .seconds(3), seldom: Duration = .seconds(12)) {
        guard routines.autoLoad, herdrHelperPoll == nil else { return }
        herdrHelperPoll = Task { [weak self] in
            let clock = ContinuousClock(); var last = clock.now - seldom
            while !Task.isCancelled, let store = self {
                let watch = store.herdrHelperWatch()
                if !watch.bots.isEmpty, clock.now - last >= (watch.often ? often : seldom) {
                    await store.refreshHerdrHelpers(for: watch.bots); last = clock.now
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// How many reads of a server may fail in a row before its bots' helpers are taken off the screen.
    static let herdrHelperFailureLimit = 5

    /// One read of `watched`. A bot whose agent is not running, or has no helper left on the server's list, shows
    /// none. A server that cannot be read keeps what it showed for a few tries, so a dropped request does not blink.
    func refreshHerdrHelpers(for watched: [Bot]) async {
        var found = herdrHelpers.filter { entry in bots.contains { $0.id == entry.key } }
        for (serverID, group) in Dictionary(grouping: watched, by: { herdrServer(for: $0).id }) {
            guard let server = herdrServer(id: serverID), let client = try? herdrClient(for: server) else { group.forEach { found[$0.id] = nil }; continue }
            do {
                let workspace = try await client.workspace()
                for bot in group {
                    let agent = client.liveAgent(named: HerdrBackend.agentName(botName: bot.name, botID: bot.id), in: workspace)
                    var list: HerdrClient.Helpers?
                    if let agent { list = try await client.helpers(of: agent, in: workspace) }
                    found[bot.id] = list?.helpers.isEmpty == false ? list : nil
                }
                herdrHelperFailures[serverID] = nil
            } catch {
                herdrHelperFailures[serverID, default: 0] += 1
                if herdrHelperFailures[serverID, default: 0] >= Self.herdrHelperFailureLimit { group.forEach { found[$0.id] = nil } }
            }
        }
        if found != herdrHelpers { herdrHelpers = found }
    }

    // MARK: Looking into one

    func isOpen(_ helper: HerdrClient.Helper, of bot: Bot) -> Bool {
        openHerdrHelper == HerdrHelperSelection(botID: bot.id, helperID: helper.id) && selectedBot?.id == bot.id && selectedGroup == nil && !showingReports
    }

    /// Shows the helper's read-only view in place of its bot's chat; opening the bot (or any chat) shows the chat again.
    func open(_ helper: HerdrClient.Helper, of bot: Bot) {
        open(bot)
        openHerdrHelper = HerdrHelperSelection(botID: bot.id, helperID: helper.id)
    }

    /// The helper's saved task and replies, its tool calls and its terminal, read from its bot's server.
    func herdrHelperLog(_ helper: HerdrClient.AgentRef, core: String, of bot: Bot) async throws -> HerdrClient.HelperLog {
        try await herdrClient(for: herdrServer(for: bot)).helperLog(core: core, helper: helper)
    }
}
