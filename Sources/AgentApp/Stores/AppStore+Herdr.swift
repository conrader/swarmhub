import Foundation

/// A bot the app offers for one agent program a server can start: its name, its template and its first model.
struct HerdrStarter: Equatable, Identifiable, Sendable {
    var id: String { template }
    let template: String; let name: String; let title: String; let model: String?
}

/// The Herdr servers (`HerdrServer`), which one each bot runs on, and the template and model each bot starts its
/// agent from. Everything here lives in `UserDefaults` and the Keychain, keyed by server or bot id, so the bot
/// record itself stays the same for every backend.
extension AppStore {
    // MARK: Servers

    /// The saved servers; with none saved, the one this install has always had (`HerdrServerList.servers`).
    var herdrServers: [HerdrServer] {
        HerdrServerList.servers(json: defaults.string(forKey: HerdrServer.listKey), legacyAddress: defaults.string(forKey: HerdrServerList.legacyAddressKey))
    }

    func saveHerdrServers(_ servers: [HerdrServer]) {
        defaults.set(HerdrServerList.json(servers), forKey: HerdrServer.listKey); objectWillChange.send()
    }

    /// A Herdr server was set up here (`FirstRun.herdrConfigured`).
    var herdrConfigured: Bool { FirstRun.herdrConfigured(defaults: defaults, keyStore: keyStore) }

    func herdrServer(id: String?) -> HerdrServer? { herdrServers.first { $0.id == id } }

    /// The server this bot's agent runs on: its own choice while that server exists, otherwise the first.
    func herdrServer(for bot: Bot) -> HerdrServer {
        let servers = herdrServers
        // `herdrServers` is never empty.
        return HerdrServerList.server(bound: defaults.string(forKey: HerdrServer.botKey(bot.id)), in: servers) ?? servers[0]
    }

    func setHerdrServer(_ id: String, for bot: Bot) {
        if id.isEmpty || id == herdrServers.first?.id { defaults.removeObject(forKey: HerdrServer.botKey(bot.id)) } else { defaults.set(id, forKey: HerdrServer.botKey(bot.id)) }
        objectWillChange.send()
    }

    func herdrBots(on server: HerdrServer) -> [Bot] { bots.filter { $0.backend == .herdr && herdrServer(for: $0).id == server.id } }

    /// The server's access token: the saved one; for the first server also the one a development launch passes in the
    /// environment (it has no Keychain of its own); for this Mac's own bridge the file its start script wrote.
    func herdrToken(for server: HerdrServer) -> String {
        let saved = keyStore.key(for: server.keyAccount)
        if !saved.isEmpty { return saved }
        if server.id == HerdrServer.defaultID, let passed = ProcessInfo.processInfo.environment[HerdrBackend.tokenEnvironment], !passed.isEmpty { return passed }
        return server.kind == .local ? HerdrServerList.localToken(homes: [NSHomeDirectory(), HerdrTunnel.realHome]) : ""
    }

    func setHerdrToken(_ token: String, for server: HerdrServer) {
        keyStore.setKey(token.trimmingCharacters(in: .whitespacesAndNewlines), for: server.keyAccount)
    }

    /// A client for one server. `token` is one typed but not saved yet (the setup window's Test). A server reached
    /// over SSH opens its forward before each request while it is not up.
    func herdrClient(for server: HerdrServer, token typed: String? = nil) throws -> HerdrClient {
        guard let baseURL = HerdrClient.validatedBaseURL(server.address) else { throw HerdrClient.Failure.invalidURL }
        let token = typed.flatMap { $0.isEmpty ? nil : $0 } ?? herdrToken(for: server)
        if token.isEmpty { throw BackendError.unavailable(HerdrBackend.missingToken) }
        var client = HerdrClient(baseURL: baseURL, token: token)
        if server.kind == .ssh { let tunnels = herdrTunnels; client.prepare = { try await tunnels.ensure(server) } }
        return client
    }

    /// The first server's client, for callers that have no bot at hand.
    func herdrClient() throws -> HerdrClient { try herdrClient(for: herdrServers[0]) }

    /// Adds a server, or replaces the one with the same id, and saves its token when one was typed. The first server
    /// an install sets up has the id `default` (`newHerdrServerID`), so it takes the place of the stand-in.
    func saveHerdrServer(_ server: HerdrServer, token: String?) {
        var servers = herdrServers
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            if servers[index] != server { herdrTunnels.close(server.id) }
            servers[index] = server
        } else { servers.append(server) }
        if let token, !token.isEmpty { setHerdrToken(token, for: server) }
        saveHerdrServers(servers)
    }

    /// Forgets a server, its token and its forward. Its bots stay and move to the first server left. The last server
    /// cannot be removed.
    func removeHerdrServer(_ server: HerdrServer) {
        var servers = herdrServers
        guard servers.count > 1, servers.contains(where: { $0.id == server.id }) else { return }
        servers.removeAll { $0.id == server.id }
        herdrTunnels.close(server.id)
        keyStore.setKey("", for: server.keyAccount)
        for bot in bots where defaults.string(forKey: HerdrServer.botKey(bot.id)) == server.id { defaults.removeObject(forKey: HerdrServer.botKey(bot.id)) }
        saveHerdrServers(servers)
    }

    /// The id a new server from the setup window or Settings is saved under: `default` while this install has none of
    /// its own yet (so the first server keeps the one Keychain account older builds used), otherwise a new one.
    func newHerdrServerID() -> String { herdrConfigured ? HerdrServerList.newID() : HerdrServer.defaultID }

    /// Test for one server: the forward opens (SSH), the bridge answers, Core is up, and what it can start.
    /// A server over SSH with no token yet reads it from the server's own file first; `found` returns it for saving.
    func testHerdrServer(_ server: HerdrServer, token typed: String? = nil) async throws -> (line: String, token: String?) {
        var found: String?
        if server.kind == .ssh, (typed ?? "").isEmpty, herdrToken(for: server).isEmpty {
            found = try await HerdrTunnel.run(HerdrServerList.remoteTokenCommand, on: server)
        }
        let client = try herdrClient(for: server, token: found ?? typed)
        let line = try await HerdrBackend(client: client, botName: "", botID: UUID(), template: nil).testConnection()
        return (line, found)
    }

    // MARK: A bot's agent

    /// The bot's own template, else the one chosen for new bots; nil lets the bridge's first usable template run.
    func herdrTemplate(for bot: Bot) -> String? {
        let own = defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? ""
        let shared = defaults.string(forKey: HerdrBackend.templateKey) ?? ""
        return own.isEmpty ? (shared.isEmpty ? nil : shared) : own
    }

    func setHerdrTemplate(_ template: String, for bot: Bot) {
        if template.isEmpty { defaults.removeObject(forKey: HerdrBackend.botTemplateKey(bot.id)) } else { defaults.set(template, forKey: HerdrBackend.botTemplateKey(bot.id)) }
    }

    /// The model this bot's next agent starts on; empty for the agent program's own default.
    func herdrModel(for bot: Bot) -> String { defaults.string(forKey: HerdrBackend.botModelKey(bot.id)) ?? "" }

    func setHerdrModel(_ model: String, for bot: Bot) {
        if model.isEmpty { defaults.removeObject(forKey: HerdrBackend.botModelKey(bot.id)) } else { defaults.set(model, forKey: HerdrBackend.botModelKey(bot.id)) }
    }

    /// The bot's instructions go out as every backend sends them (`outboundPersona`: a bot imported from Grok has its
    /// secrets blanked), which matters for a bot moved here from Hermes.
    func herdrBackend(for bot: Bot) throws -> HerdrBackend {
        var backend = HerdrBackend(client: try herdrClient(for: herdrServer(for: bot)), botName: bot.name, botID: bot.id, template: herdrTemplate(for: bot), model: herdrModel(for: bot), instructions: bot.outboundPersona)
        backend.steers = herdrSteers(bot)
        // The main bot is told how to create bots; every other bot how to ask it for one.
        if createsHerdrBots(bot) { backend.creationNote = herdrAsksFirst(bot) ? Self.herdrCreationNoteAsking : Self.herdrCreationNote }
        else if bot.backend == .herdr, !bot.isReadOnlyArchive { backend.askNote = HerdrBotAsk.note(main: herdrMainBot(on: herdrServer(for: bot))?.name) }
        if startsHerdrHelpers(bot) { backend.helperNote = HerdrHelperNote.text }
        // Every bot is told how to write to the other bots of its server, and who they are right now.
        if bot.backend == .herdr, !bot.isReadOnlyArchive { backend.messageNote = HerdrBotMessage.note; backend.roster = herdrRoster(for: bot) }
        // A turn on the event stream brings the agent's helpers with it (`herdrLive`).
        let botID = bot.id
        backend.onLive = { [weak self] note in Task { @MainActor in self?.herdrLive(note, botID: botID) } }
        return backend
    }

    /// Reads what the bot's agent runs on (agent program, model, and what the running agent was started on) and keeps
    /// it for the Details panel and the chat header. A server that cannot be read leaves the last reading in place.
    @discardableResult func refreshHerdrAgentReading(for bot: Bot) async -> HerdrAgentReading? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive, let client = try? herdrClient(for: herdrServer(for: bot)) else { return herdrAgentReadings[bot.id] }
        let reading = try? await client.agentReading(agentName: HerdrBackend.agentName(botName: bot.name, botID: bot.id), ownTemplate: defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)),
                                                     sharedTemplate: defaults.string(forKey: HerdrBackend.templateKey), ownModel: herdrModel(for: bot))
        if let reading, herdrAgentReadings[bot.id] != reading { herdrAgentReadings[bot.id] = reading }
        return herdrAgentReadings[bot.id]
    }

    /// Steer is the default: a message sent while the agent answers goes into that answer.
    func herdrSteers(_ bot: Bot) -> Bool { defaults.object(forKey: HerdrBackend.botSteerKey(bot.id)) as? Bool ?? true }
    func setHerdrSteers(_ steers: Bool, for bot: Bot) { defaults.set(steers, forKey: HerdrBackend.botSteerKey(bot.id)) }

    /// Ends the bot's running agent, so its next message starts a fresh one on the chosen runtime and model.
    /// Returns whether an agent was running. The chat stays; the agent's own memory of it does not.
    func restartHerdrAgent(for bot: Bot) async throws -> Bool {
        let backend = try herdrBackend(for: bot)
        guard let agent = backend.client.liveAgent(named: backend.agentName, in: try await backend.client.workspace()) else { return false }
        try await backend.client.end(agent)
        return true
    }

    /// The templates a server's Core can start right now, for the pickers.
    func herdrTemplates(on server: HerdrServer) async throws -> [HerdrClient.Template] {
        try await herdrClient(for: server).workspace().templates.filter { $0.error == nil }
    }

    // MARK: Starter bots

    /// The model a starter bot begins on: the first one the server offers for that agent program. The server's catalog
    /// decides which that is, because the app itself names no model; nil leaves the agent program's own default.
    static func starterModel(offered: [HerdrClient.Template.Model]) -> String? { HerdrClient.defaultModel(offered: offered) }

    /// One starter per agent program the server can start (Claude Code, Codex), each on its starter model. Reads the
    /// server; adds nothing.
    func herdrStarters(client: HerdrClient) async throws -> [HerdrStarter] {
        let usable = try await client.workspace().templates.filter { $0.error == nil }
        var starters: [HerdrStarter] = []
        for (harness, name) in [("Claude Code", "Claude"), ("Codex", "Codex")] {
            guard let template = usable.first(where: { $0.runtime?.harness == harness }) else { continue }
            let offered = (try? await client.models(for: template)) ?? template.models ?? []
            starters.append(HerdrStarter(template: template.name, name: name, title: "\(harness) on Herdr", model: Self.starterModel(offered: offered)))
        }
        return starters
    }

    /// The starters this server's bots do not cover yet: neither their template nor their name is taken there.
    func missingHerdrStarters(_ starters: [HerdrStarter], on server: HerdrServer) -> [HerdrStarter] {
        let present = herdrBots(on: server), taken = Set(present.compactMap { herdrTemplate(for: $0) })
        return starters.filter { starter in !taken.contains(starter.template) && !present.contains { $0.name == starter.name } }
    }

    /// Adds the starters as bots on `server`, without a network call. A second server's bots say where they run.
    @discardableResult func addHerdrStarters(_ starters: [HerdrStarter], on server: HerdrServer) -> [Bot] {
        let first = server.id == herdrServers.first?.id
        var added: [Bot] = []
        for starter in missingHerdrStarters(starters, on: server) {
            let bot = Bot(name: starter.name, title: first ? starter.title : "\(starter.title) · \(server.name)", persona: Bot.defaultPersona, backend: .herdr)
            bots.append(bot); added.append(bot)
            setHerdrServer(server.id, for: bot); setHerdrTemplate(starter.template, for: bot); setHerdrModel(starter.model ?? "", for: bot)
        }
        return added
    }

    /// One ready-to-use bot per agent program the server can start, each on its starter model. A program that
    /// already has a Herdr bot on that server is skipped. Returns the names it added.
    func addHerdrStarterBots(on server: HerdrServer? = nil) async throws -> [String] {
        let server = server ?? herdrServers[0]
        let added = addHerdrStarters(try await herdrStarters(client: try herdrClient(for: server)), on: server)
        if !added.isEmpty { removeSampleBots(); objectWillChange.send(); save() }
        return added.map(\.name)
    }

    // MARK: Moving a bot to Herdr

    /// Bots of the older backends that can become Herdr bots (not samples, not read-only archives).
    var botsMovableToHerdr: [Bot] { bots.filter { ($0.backend == .hermes || $0.backend == .openClaw) && !$0.isDemo && !$0.isReadOnlyArchive } }

    /// Makes `bot` a Herdr bot on `server` in place: the same record, so its name, avatar, chat history and settings
    /// stay. Its instructions stay too; a bot whose real instructions lived on its box (the app only held a copy the
    /// manager showed) takes that copy, because a Herdr agent gets nothing but what the app sends it. Everything the
    /// old backend needs is left on the record, so switching Backend back restores it. The caller saves.
    func moveToHerdr(_ bot: Bot, server: HerdrServer? = nil) {
        guard bot.backend != .herdr, !bot.isReadOnlyArchive else { return }
        let own = bot.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if own.isEmpty || bot.persona == Bot.defaultPersona, let onBox = bot.boxInstructions?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !onBox.isEmpty {
            bot.persona = onBox
        }
        bot.backend = .herdr
        setHerdrServer((server ?? herdrServers[0]).id, for: bot)
    }

    /// Moves every bot of the older backends to `server`. Returns how many moved.
    @discardableResult func moveAllToHerdr(server: HerdrServer? = nil) -> Int {
        let moving = botsMovableToHerdr
        for bot in moving { moveToHerdr(bot, server: server) }
        if !moving.isEmpty { objectWillChange.send(); save() }
        return moving.count
    }
}
