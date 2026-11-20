import Foundation

/// The setup wizard's Herdr path. Test saves nothing: it builds the server from the typed fields, opens the SSH
/// forward when the server needs one, and reads what the server can run. Only the wizard's last button writes
/// (`commitSetupWizard`), so a window closed earlier leaves nothing half set up.
extension AppStore {
    /// The id the draft's server is tested and saved under: a server at the same place keeps its id (the last button
    /// then updates it), also the one that stands in while no list is saved; otherwise a new one (`newHerdrServerID`).
    func setupHerdrID(for draft: HerdrServerDraft) -> String {
        guard let candidate = draft.server(id: "") else { return newHerdrServerID() }
        return herdrServers.first { $0.kind == candidate.kind && $0.address == candidate.address && $0.sshHost == candidate.sshHost && $0.sshUser == candidate.sshUser }?.id ?? newHerdrServerID()
    }

    /// Connect's Test, and the reading of a server that is already set up. "This Mac" first looks whether anything
    /// answers on the port at all, so a Mac with no Herdr running gets the how-to-start lines instead of an error.
    /// Every other failure comes back as its own plain line (`HerdrSetupProblem`): a server that cannot be reached, an
    /// access key it does not accept, Herdr Core not running beside it. A server with no agent program is `connected`
    /// with an empty offer, which the wizard does not let through.
    func testSetupHerdr(_ draft: HerdrServerDraft) async -> HerdrSetupOutcome {
        guard let server = draft.server(id: setupHerdrID(for: draft)) else { return .failed(draft.problem ?? SetupCopy.failed) }
        if server.kind == .local, await !HerdrTunnels.answers(port: server.port) { return .nothingHere(port: server.port) }
        var found: String?
        if server.kind == .ssh, draft.typedKey.isEmpty, herdrToken(for: server).isEmpty {
            // A server over SSH with no access key yet: it is read from the server's own file first.
            do { found = try await herdrTunnels.readToken(on: server) }
            catch { return setupConnectionFailure(error, server: server, readingKey: true) }
        }
        let key = draft.typedKey.isEmpty ? found : draft.typedKey
        do { return .connected(server: server, key: key, offer: try await herdrClient(for: server, token: key).offer()) }
        catch { return setupConnectionFailure(error, server: server) }
    }

    private func setupConnectionFailure(_ error: Error, server: HerdrServer, readingKey: Bool = false) -> HerdrSetupOutcome {
        if server.kind == .ssh, HerdrTunnel.offersPassword(error) { return .sshLoginRequired(server) }
        return .failed(HerdrSetupProblem.of(error, readingKey: readingKey).line(for: server))
    }

    /// "This Mac", before its Test: the port its service is on, or will be put on, when that is not the one in the
    /// draft. The usual port can lead somewhere else: a forward to a server of yours answers there. The service this
    /// Mac already has says its own port; with none here and no access key for what answers, the next port that
    /// nothing uses is taken, so setting this Mac up does not stop at a question about a key or a port.
    /// nil: the draft's port stands (also when the person typed a key, which says the port is meant).
    func thisMacPort(for draft: HerdrServerDraft) async -> Int? {
        guard draft.kind == .local, draft.typedKey.isEmpty, let server = draft.server(id: setupHerdrID(for: draft)) else { return nil }
        let own = await localReport(port: nil)
        return await Self.thisMacPort(wanted: server.port, ownPort: own?.service.installed == true ? own?.port : nil, hasKey: !herdrToken(for: server).isEmpty,
                                      answers: { await HerdrTunnels.answers(port: $0) }, free: { HerdrTunnels.freePort(after: $0) })
    }

    /// The rule of `thisMacPort(for:)`, with what it reads passed in.
    nonisolated static func thisMacPort(wanted: Int, ownPort: Int?, hasKey: Bool, answers: @Sendable (Int) async -> Bool, free: @Sendable (Int) -> Int?) async -> Int? {
        if let ownPort { return ownPort == wanted ? nil : ownPort }
        guard !hasKey, await answers(wanted) else { return nil }
        return free(wanted)
    }

    /// Cancel, Back to Welcome or closing the window: a forward Test opened for a server that was never saved is closed.
    func abandonSetupHerdr(_ server: HerdrServer?) {
        guard let server, server.kind == .ssh, herdrServers.first(where: { $0.id == server.id }) != server else { return }
        herdrTunnels.close(server.id)
    }

    /// How the wizard opens: on the main bot of a server that is set up and has none yet (Connect is skipped),
    /// otherwise on where bots run: nothing is set up, or every server has its main bot and the person wants another server.
    func wizardStart() -> SetupFlow {
        guard herdrConfigured, let server = herdrServers.first(where: { herdrMainBot(on: $0) == nil }) else { return SetupFlow() }
        return SetupFlow(saved: server)
    }

    /// Settings' button opens the wizard on where bots run: every server that is set up already has its main bot.
    var setupAddsServer: Bool { herdrConfigured && herdrServers.allSatisfy { herdrMainBot(on: $0) != nil } }

    /// The bots already on `server`, as the wizard needs them: one can stay or become the main bot, their names are
    /// taken, and their agent programs need no second bot.
    func setupHerdrBots(on server: HerdrServer) -> [HerdrSetupBot] {
        herdrBots(on: server).filter { !$0.isDemo && !$0.isReadOnlyArchive }.map { HerdrSetupBot(id: $0.id, name: $0.name, isMain: createsHerdrBots($0), template: herdrTemplate(for: $0), needsFirstConnection: $0.grokSourceID != nil && !herdrConfigured) }
    }

    /// The wizard's last button, with no network call: saves the server (and the access key Test used, when one was
    /// typed or read from the server), creates the main bot or gives an existing bot that role, adds one bot per
    /// ticked agent program, removes sample bots, selects the main bot and marks setup done. A new bot keeps no model
    /// of its own unless one was chosen, so it starts on the first model the server offers. Restores everything if
    /// saving fails. Returns the main bot.
    /// `projects`: the projects on other servers chosen for the main bot on the wizard's last step; its first agent starts with them.
    @discardableResult func commitSetupWizard(server: HerdrServer?, key: String?, main: HerdrMainBotDraft, more: [HerdrProgram], offer: HerdrOffer?, projects: [HerdrBotProject] = []) throws -> Bot {
        guard persistenceEnabled, storeRestoreOffer == nil, let server, let offer else { throw SetupCommitError.notTested }
        let kept = main.keep.flatMap { id in bots.first { $0.id == id && $0.backend == .herdr && !$0.isReadOnlyArchive } }
        let connectingImport = kept?.grokSourceID != nil && !herdrConfigured
        if connectingImport, offer.program(main.template) == nil { throw SetupCommitError.nothingChosen }
        if main.keep != nil, kept == nil { throw SetupCommitError.notTested }
        if kept == nil, main.trimmedName.isEmpty || offer.program(main.template) == nil { throw SetupCommitError.nothingChosen }
        // A name already on the server is refused here too, so a button pressed twice never makes a second main bot.
        if kept == nil, herdrBots(on: server).contains(where: { $0.name.lowercased() == main.trimmedName.lowercased() }) { throw SetupCommitError.nothingChosen }
        let transaction = SetupTransaction(self), defaults = defaults
        transaction.captureDefaults([HerdrServer.listKey, FirstRun.stateKey])
        transaction.captureBots()
        let roles = bots.map { ($0, $0.canManageBots) }
        transaction.record { for (bot, role) in roles { bot.canManageBots = role } }
        return try transaction.run {
            if let key, !key.isEmpty { transaction.setKey(key, for: server.keyAccount) }
            saveHerdrServer(server, token: nil)
            let first = server.id == herdrServers.first?.id
            /// A new bot on `server`, starting from `template`; what the app keeps beside its record goes if saving fails.
            let add = { (bot: Bot, template: String, model: String, index: Int?) in
                self.bots.insert(bot, at: index ?? self.bots.count)
                transaction.record { for key in [HerdrServer.botKey(bot.id), HerdrBackend.botTemplateKey(bot.id), HerdrBackend.botModelKey(bot.id)] { defaults.removeObject(forKey: key) } }
                self.setHerdrServer(server.id, for: bot); self.setHerdrTemplate(template, for: bot); self.setHerdrModel(model, for: bot)
            }
            let mainBot: Bot
            if let kept { mainBot = kept } else {
                mainBot = Bot(name: main.trimmedName, persona: main.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Bot.defaultPersona : main.instructions, backend: .herdr)
                main.avatar.apply(to: mainBot)
                mainBot.offersReleaseNotesExample = true
                add(mainBot, main.template, main.model, 0)
            }
            if connectingImport {
                transaction.captureDefaults([HerdrBackend.botTemplateKey(mainBot.id), HerdrBackend.botModelKey(mainBot.id)])
                setHerdrTemplate(main.template, for: mainBot)
                setHerdrModel(main.model, for: mainBot)
            }
            if kept == nil || connectingImport {
                transaction.captureDefaults([Self.herdrHelpersKey(mainBot.id), Self.herdrAsksFirstKey(mainBot.id)])
                setStartsHerdrHelpers(main.allowHelpers, for: mainBot)
                setHerdrAsksFirst(true, for: mainBot)
            }
            if !projects.isEmpty {
                let before = herdrProjects(for: mainBot), id = mainBot.id
                transaction.captureDefaults([Self.herdrProjectsKey(id), Self.herdrProjectsChangedKey(id)])
                // A main bot that stays keeps the projects it has and gains the chosen ones.
                setHerdrProjects(before + projects.filter { chosen in !before.contains { $0.id == chosen.id } }, for: mainBot)
            }
            // One main bot per server.
            for other in herdrBots(on: server) where other.id != mainBot.id { other.canManageBots = false }
            mainBot.canManageBots = true
            for program in more where offer.program(program.template) != nil {
                add(Bot(name: program.name, title: first ? "" : Self.starterTitle("", on: server), persona: Bot.defaultPersona, backend: .herdr), program.template, HerdrModelChoice.recommended, nil)
            }
            removeSampleBots()
            selectedBot = mainBot; selectedGroup = nil; rememberSelection(bot: mainBot)
            // The chat the wizard ends in says once that the first reply takes longer, when it has to start an agent.
            herdrLanding = offer.startsAgent(named: HerdrBackend.agentName(botName: mainBot.name, botID: mainBot.id)) ? (mainBot.id, mainBot.messages.count) : nil
            FirstRun.record(.done, in: defaults)
            objectWillChange.send()
            try saveThrowing()
            return mainBot
        }
    }

    /// Under the composer of a Herdr bot whose next message starts its agent: a bot nobody has written to yet, or the
    /// main bot the wizard just ended on. Gone once a message is in the chat, or when the server says an agent runs.
    func herdrFirstReplyHint(for bot: Bot) -> String? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive, !bot.isDemo else { return nil }
        let landed = herdrLanding.map { $0.bot == bot.id && $0.messages == bot.messages.count } ?? false
        guard bot.messages.isEmpty || landed else { return nil }
        if let reading = herdrAgentReadings[bot.id], reading.running != .none { return nil }
        // Its agent is running or is started ahead of time as the chat opens: the header says so, and nothing waits
        // for the first message.
        if herdrReadiness[bot.id] != nil || herdrWarming[bot.id] != nil || (launchWorkEnabled && herdrKeepsReady(bot) && herdrStartsAhead(for: bot)) { return nil }
        return WizardCopy.firstReply(bot.name)
    }
}
