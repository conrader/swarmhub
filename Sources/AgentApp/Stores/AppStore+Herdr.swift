import Foundation

/// A bot the app offers for one agent program a server can start: its name, its template and its first model.
struct HerdrStarter: Equatable, Identifiable, Sendable {
    var id: String { template }
    let template: String; let name: String; let title: String; let model: String?
}

/// The Herdr servers (`HerdrServer`), which one each bot runs on, and the template and model each bot starts its
/// agent from. Everything here lives in `UserDefaults` and the Keychain, keyed by server or bot id.
extension AppStore {
    // MARK: Servers

    /// The saved servers; with none saved, the one this install has always had (`HerdrServerList.servers`).
    var herdrServers: [HerdrServer] {
        let json = defaults.string(forKey: HerdrServer.listKey)
        let legacy = defaults.string(forKey: HerdrServerList.legacyAddressKey)
        if let cachedServerList, cachedServerList.json == json, cachedServerList.legacy == legacy { return cachedServerList.servers }
        let servers = HerdrServerList.servers(json: json, legacyAddress: legacy)
        cachedServerList = (json, legacy, servers)
        return servers
    }

    func saveHerdrServers(_ servers: [HerdrServer]) {
        defaults.set(HerdrServerList.json(servers), forKey: HerdrServer.listKey); objectWillChange.send()
    }

    /// A Herdr server was set up here (`FirstRun.herdrConfigured`).
    var herdrConfigured: Bool { FirstRun.herdrConfigured(defaults: defaults, keyStore: keyStore) }

    func herdrServer(id: String?) -> HerdrServer? { herdrServers.first { $0.id == id } }

    /// The server this bot's agent runs on: its own choice while that server exists, otherwise the first.
    func herdrServer(for bot: Bot) -> HerdrServer {
        herdrServer(for: bot, in: herdrServers)
    }

    func herdrServer(for bot: Bot, in servers: [HerdrServer]) -> HerdrServer {
        // `herdrServers` is never empty.
        return HerdrServerList.server(bound: defaults.string(forKey: HerdrServer.botKey(bot.id)), in: servers) ?? servers[0]
    }

    func setHerdrServer(_ id: String, for bot: Bot) {
        let previous = herdrServer(for: bot)
        let next = herdrServer(id: id) ?? herdrServers[0]
        if previous.id != next.id { setHerdrProjects([], for: bot) }
        defaults.set(next.id, forKey: HerdrServer.botKey(bot.id))
        if previous.id != next.id { forgetHerdrAgentState(for: bot) }
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
        var client: HerdrClient
        if server.kind == .ssh {
            let tunnels = herdrTunnels
            let reserved = Set(herdrServers.filter { $0.kind != .ssh }.map(\.port))
            let port = try tunnels.forwardPort(for: server, avoiding: reserved)
            guard let forwardedURL = URL(string: HerdrServer.loopback(port: port)) else { throw HerdrClient.Failure.invalidURL }
            client = HerdrClient(baseURL: forwardedURL, token: token)
            client.forwardedHost = "127.0.0.1:\(server.port)"
            client.prepare = { try await tunnels.ensure(server, avoiding: reserved) }
        } else {
            client = HerdrClient(baseURL: baseURL, token: token)
        }
        herdrClientSetup?(&client)
        return client
    }

    /// The first server's client, for callers that have no bot at hand.
    func herdrClient() throws -> HerdrClient { try herdrClient(for: herdrServers[0]) }

    /// Adds a server, or replaces the one with the same id, and saves its token when one was typed. The first server
    /// an install sets up has the id `default` (`newHerdrServerID`), so it takes the place of the stand-in.
    func saveHerdrServer(_ server: HerdrServer, token: String?) {
        var servers = herdrServers
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            let old = servers[index]
            if old.kind != server.kind || old.address != server.address ||
                old.sshHost != server.sshHost || old.sshUser != server.sshUser {
                for bot in herdrBots(on: old) {
                    setHerdrProjects([], for: bot)
                    forgetHerdrAgentState(for: bot)
                }
            }
            if old != server { herdrTunnels.close(server.id) }
            if old.sshHost != server.sshHost || old.sshUser != server.sshUser { herdrTunnels.forgetPassword(for: old) }
            servers[index] = server
        } else { servers.append(server) }
        if let token, !token.isEmpty { setHerdrToken(token, for: server) }
        saveHerdrServers(servers)
        if launchWorkEnabled { personSettings(for: server).refresh() }
    }

    /// Forgets a server, its token and its forward. Its bots stay and move to the first server left. The last server
    /// cannot be removed.
    func removeHerdrServer(_ server: HerdrServer) {
        let servers = herdrServers
        let remaining = servers.filter { $0.id != server.id }
        guard remaining.count < servers.count, let fallback = remaining.first else { return }
        let moving = herdrBots(on: server)
        // Resolve both roles before changing any bindings. The surviving server has first claim.
        let flags = Array(flaggedHerdrBots(on: fallback)) + Array(flaggedHerdrBots(on: server))
        let revoked = flags.dropFirst()
        if !revoked.isEmpty {
            for bot in revoked { bot.canManageBots = false }
            save()
            if persistenceEnabled && turns.saveFailing {
                for bot in revoked { bot.canManageBots = true }
                return
            }
        }
        for bot in moving {
            setHerdrProjects([], for: bot)
            defaults.removeObject(forKey: HerdrServer.botKey(bot.id))
            forgetHerdrAgentState(for: bot)
        }
        herdrTunnels.forgetPassword(for: server)
        herdrTunnels.release(server.id)
        keyStore.setKey("", for: server.keyAccount)
        // Its bots move to another server, which has its own projects: the ones chosen on this server do not go with them.
        herdrProjectModels[server.id] = nil
        saveHerdrServers(remaining)
    }

    /// The id a new server from the setup window or Settings is saved under: `default` while this install has none of
    /// its own yet (so the first server keeps the one Keychain account older builds used), otherwise a new one.
    func newHerdrServerID() -> String { herdrConfigured ? HerdrServerList.newID() : HerdrServer.defaultID }

    /// Test for one server: the forward opens (SSH), the bridge answers, Core is up, and what it can start.
    /// A server over SSH with no token yet reads it from the server's own file first; `found` returns it for saving.
    func testHerdrServer(_ server: HerdrServer, token typed: String? = nil) async throws -> (line: String, token: String?) {
        var found: String?
        if server.kind == .ssh, (typed ?? "").isEmpty, herdrToken(for: server).isEmpty {
            found = try await herdrTunnels.readToken(on: server)
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
        if (defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? "") != template { markModelSwitch(bot) }
        if template.isEmpty { defaults.removeObject(forKey: HerdrBackend.botTemplateKey(bot.id)) } else { defaults.set(template, forKey: HerdrBackend.botTemplateKey(bot.id)) }
    }

    /// The model this bot's next agent starts on; empty for the agent program's own default.
    func herdrModel(for bot: Bot) -> String { defaults.string(forKey: HerdrBackend.botModelKey(bot.id)) ?? "" }

    func setHerdrModel(_ model: String, for bot: Bot) {
        if herdrModel(for: bot) != model { markModelSwitch(bot) }
        if model.isEmpty { defaults.removeObject(forKey: HerdrBackend.botModelKey(bot.id)) } else { defaults.set(model, forKey: HerdrBackend.botModelKey(bot.id)) }
    }

    /// The bot's instructions go out as `outboundPersona` (a bot imported from Grok has its secrets blanked).
    func herdrBackend(for bot: Bot) throws -> HerdrBackend {
        let liveServer = herdrServer(for: bot)
        var backend = HerdrBackend(client: try herdrClient(for: liveServer), botName: bot.name, botID: bot.id, template: herdrTemplate(for: bot), model: herdrModel(for: bot), instructions: bot.outboundPersona)
        if launchWorkEnabled {
            let server = herdrServer(for: bot), id = bot.id
            backend.coordinate = { [weak self] in
                do { return try await self?.ensureTeam(server) ?? false }
                catch let failure as HerdrClient.Failure where failure == .unauthorized || failure == .refusedHost {
                    throw failure
                }
                catch {
                    if await self?.teamPreviouslyRegistered(id, on: server) == true { return true }
                    throw error
                }
            }
        }
        backend.confirmation = modelConfirmation(bot)
        backend.serverID = herdrServer(for: bot).id
        // A bot imported from Grok Bot: its agent reads the imported conversation before a message, once per agent session.
        // And a bot whose program or model was changed: its fresh agent reads the bot's chat so far (`AppStore+HerdrCarryOver.swift`).
        backend.handoff = grokHandoffSource(for: bot) ?? herdrCarrySource(for: bot)
        if launchWorkEnabled && !bot.isDemo && !bot.isReadOnlyArchive {
            let server = herdrServer(for: bot), template = herdrTemplate(for: bot), model = herdrModel(for: bot)
            backend.prepareDirect = { [weak self, weak bot] in
                guard let self, let bot else { throw CancellationError() }
                return try await self.prepareDirectModel(bot: bot, server: server, template: template, model: model)
            }
        }
        backend.steers = herdrSteers(bot)
        // The main bot is told how to create bots; every other bot how to ask it for one.
        if createsHerdrBots(bot) { backend.creationNote = herdrAsksFirst(bot) ? Self.herdrCreationNoteAsking : Self.herdrCreationNote }
        else if bot.backend == .herdr, !bot.isReadOnlyArchive { backend.askNote = HerdrBotAsk.note(main: herdrMainBot(on: herdrServer(for: bot))?.name) }
        if startsHerdrHelpers(bot) { backend.helperNote = HerdrHelperNote.text }
        // Every bot is told how to write to the other bots of its server, and who they are right now.
        if bot.backend == .herdr, !bot.isReadOnlyArchive { backend.messageNote = HerdrBotMessage.note; backend.roster = herdrRoster(for: bot) }
        // Every bot reads "About you"; the main bot is also told how to propose an addition to it.
        if bot.backend == .herdr, !bot.isReadOnlyArchive { backend.aboutYou = HerdrAboutYou.note(aboutYou) }
        if createsHerdrBots(bot) { backend.aboutHow = HerdrAboutYou.how }
        // The main bot is told how to have the app change the bots' models; every other bot, who can.
        if createsHerdrBots(bot) { backend.modelBrief = HerdrModelRequest.brief; backend.modelHow = HerdrModelRequest.how }
        else if bot.backend == .herdr, !bot.isReadOnlyArchive { backend.modelHow = HerdrModelRequest.elsewhere(main: herdrMainBot(on: herdrServer(for: bot))?.name) }
        // A turn on the event stream brings the agent's helpers with it (`herdrLive`).
        let botID = bot.id
        // A start ahead of time that is on its way: the message waits for it and then finds that agent.
        if let warming = herdrWarming[botID] { backend.starting = .init(program: herdrProgramName(for: bot), settled: { await warming.value }) }
        backend.onLive = { [weak self] note, groupRuntime in
            Task { @MainActor in
                guard let self, let current = self.bots.first(where: { $0.id == botID }), self.herdrServer(for: current) == liveServer else { return }
                self.herdrLive(note, botID: botID, groupRuntime: groupRuntime)
            }
        }
        // The projects on other servers it may use; a running agent that has an older list gets this one with the next message.
        let projects = herdrProjects(for: bot)
        backend.projects = projects; backend.projectsChanged = herdrProjectsChanged(bot)
        backend.onProjectsSynced = { [weak self] in
            Task { @MainActor in
                guard let self, let bot = self.bots.first(where: { $0.id == botID }), self.herdrProjects(for: bot) == projects else { return }
                self.defaults.removeObject(forKey: Self.herdrProjectsChangedKey(botID))
            }
        }
        return backend
    }

    /// Reads what the bot's agent runs on (agent program, model, and what the running agent was started on) and keeps
    /// it for the Details panel and the chat header. A server that cannot be read leaves the last reading in place.
    @discardableResult func refreshHerdrAgentReading(for bot: Bot, requireFresh: Bool = false) async -> HerdrAgentReading? {
        let server = herdrServer(for: bot)
        guard bot.backend == .herdr, !bot.isReadOnlyArchive, let client = try? herdrClient(for: server) else { return requireFresh ? nil : herdrAgentReadings[bot.id] }
        let template = defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id))
        let shared = defaults.string(forKey: HerdrBackend.templateKey)
        let model = herdrModel(for: bot)
        let presence = herdrAgentPresence[bot.id]
        var reading = try? await client.agentReading(agentName: HerdrBackend.agentName(botName: bot.name, botID: bot.id), ownTemplate: template,
                                                     sharedTemplate: shared, ownModel: model)
        guard server == herdrServer(for: bot), model == herdrModel(for: bot),
              template == defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)),
              shared == defaults.string(forKey: HerdrBackend.templateKey) else { return nil }
        if let record = modelConfirmation(bot), record.matches(server: herdrServer(for: bot).id, core: reading?.core, agent: reading?.session), reading?.confirmed == false {
            reading?.running = .model(id: record.id, label: record.label)
            reading?.confirmed = true
        }
        if let reading {
            if herdrAgentReadings[bot.id] != reading { herdrAgentReadings[bot.id] = reading }
            if let presence, presence.session != reading.session, herdrAgentPresence[bot.id] == presence {
                herdrAgentPresence[bot.id] = nil
            }
        }
        return requireFresh ? reading : herdrAgentReadings[bot.id]
    }

    func modelConfirmation(_ bot: Bot) -> HerdrModelConfirmation? {
        defaults.data(forKey: "herdr.confirmed.\(bot.id)").flatMap { try? JSONDecoder().decode(HerdrModelConfirmation.self, from: $0) }
    }

    func rememberModel(_ record: HerdrModelConfirmation, for bot: Bot) {
        defaults.set(try? JSONEncoder().encode(record), forKey: "herdr.confirmed.\(bot.id)")
    }

    /// Steer is the default: a message sent while the agent answers goes into that answer.
    func herdrSteers(_ bot: Bot) -> Bool { defaults.removeObject(forKey: HerdrBackend.botSteerKey(bot.id)); return true }

    /// Ends the bot's running agent, so its next message starts a fresh one on the chosen runtime and model.
    /// Returns whether an agent was running. The chat stays; the agent's own memory of it does not.
    func restartHerdrAgent(for bot: Bot) async throws -> Bool {
        // A start ahead of time that is on its way is let through first, so the agent it starts is the one ended.
        await herdrWarming[bot.id]?.value
        let backend = try herdrBackend(for: bot)
        let workspace = try await backend.client.workspace()
        let agent = backend.client.liveAgent(named: backend.agentName, in: workspace)
        guard let agent else { return false }
        try await backend.client.end(agent)
        herdrReadiness[bot.id] = nil
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

    /// One starter per agent program the server can start, named as the server names the program, each on its
    /// starter model. Reads the server; adds nothing.
    func herdrStarters(client: HerdrClient) async throws -> [HerdrStarter] {
        let usable = try await client.workspace().templates.filter { $0.error == nil }
        var starters: [HerdrStarter] = []
        for template in usable {
            // Two templates of one program make one starter, the first.
            // A bot is named after its program without the server's "(beta)".
            guard let name = template.programName.map(HerdrProgramName.botName), !starters.contains(where: { $0.name == name }) else { continue }
            let offered = (try? await client.models(for: template)) ?? template.models ?? []
            starters.append(HerdrStarter(template: template.name, name: name, title: "", model: Self.starterModel(offered: offered)))
        }
        return starters
    }

    /// The starters this server's bots do not cover yet: neither their template nor their name is taken there.
    func missingHerdrStarters(_ starters: [HerdrStarter], on server: HerdrServer) -> [HerdrStarter] {
        let present = herdrBots(on: server), taken = Set(present.compactMap { herdrTemplate(for: $0) })
        return starters.filter { starter in !taken.contains(starter.template) && !present.contains { $0.name == starter.name } }
    }

    /// Adds the starters as bots on `server`, without a network call. A second server's bots say where they run, as
    /// the few words under their name.
    @discardableResult func addHerdrStarters(_ starters: [HerdrStarter], on server: HerdrServer) -> [Bot] {
        let first = server.id == herdrServers.first?.id
        var added: [Bot] = []
        for starter in missingHerdrStarters(starters, on: server) {
            let bot = Bot(name: starter.name, title: first ? starter.title : Self.starterTitle(starter.title, on: server), persona: Bot.defaultPersona, backend: .herdr)
            bots.append(bot); added.append(bot)
            setHerdrServer(server.id, for: bot); setHerdrTemplate(starter.template, for: bot); setHerdrModel(starter.model ?? "", for: bot)
        }
        return added
    }

    /// "On Box" for a bot on a server that is not the first; a title of its own comes before it.
    static func starterTitle(_ title: String, on server: HerdrServer) -> String { title.isEmpty ? "On \(server.name)" : "\(title) · \(server.name)" }

    /// One ready-to-use bot per agent program the server can start, each on its starter model. A program that
    /// already has a Herdr bot on that server is skipped. Returns the names it added.
    func addHerdrStarterBots(on server: HerdrServer? = nil) async throws -> [String] {
        let server = server ?? herdrServers[0]
        let added = addHerdrStarters(try await herdrStarters(client: try herdrClient(for: server)), on: server)
        if !added.isEmpty { removeSampleBots(); objectWillChange.send(); save() }
        return added.map(\.name)
    }

}
