import Foundation

/// A request for one chat's composer (the Manage bots menu, the bot editor).
struct ComposerFill: Equatable { let id = UUID(); let botID: UUID; let text: String }

/// A bot's instructions on the box as the manager last showed them; `stale` once the manager reports a change.
struct BoxInstructions: Codable, Equatable { var text: String?; var fetchedAt: Date?; var stale = false }

/// A profile the manager listed that SwarmHub has no bot for.
struct BotOffer: Identifiable, Equatable {
    enum State: Equatable { case offered, adding, needsKey, unreachable }
    var id: String { name }
    let name: String; let description: String; var state: State = .offered
}

/// P22: the main bot manages the other bots with stock Hermes; SwarmHub sends it the manager text on demand only and
/// applies the swarmhub blocks it returns. New bots' keys are derived, never sent. P27 adds skills the manager installs
/// on Konrad's press (AppStore+Skills.swift); Hermes itself is never changed.
/// P26: an OpenClaw agent can hold the role for its Gateway (`AppStore+BotManagerOpenClaw.swift`).
extension AppStore {
    static let managerMigrationKey = "p22.managerRoleMigrated"
    private static let cachedTemplate = BotManagerText.fullTemplate()
    private static let cachedOpenClawTemplate = BotManagerText.template(for: .openClaw)

    // MARK: Manager role

    /// The base URL a Hermes bot talks to, as `backend(for:)` resolves it; `openclaw:<gatewayID>` for an OpenClaw bot (P26).
    func connection(of bot: Bot) -> String {
        if bot.backend == .openClaw { return "openclaw:\(bot.openClaw?.gatewayID ?? "")" }
        let raw = bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    /// Hermes bots, and OpenClaw bots bound to a Gateway agent, can hold the role.
    func canHoldManagerRole(_ bot: Bot) -> Bool { bot.backend == .hermes || (bot.backend == .openClaw && bot.openClaw != nil) }

    func isManager(_ bot: Bot) -> Bool { bot.canManageBots && canHoldManagerRole(bot) && !bot.isReadOnlyArchive }

    /// The manager bot on this bot's backend connection (one per Hermes base URL, one per OpenClaw Gateway).
    func manager(for bot: Bot) -> Bot? {
        guard canHoldManagerRole(bot) else { return nil }
        let target = connection(of: bot)
        return bots.first { isManager($0) && connection(of: $0) == target }
    }

    /// Turns the role on for one bot (and off for any other manager on its connection), or off.
    func setCanManageBots(_ bot: Bot, _ on: Bool) {
        guard on else { bot.canManageBots = false; objectWillChange.send(); save(); return }
        guard canHoldManagerRole(bot) else { return }
        let target = connection(of: bot)
        for other in bots where other.id != bot.id && other.canManageBots && connection(of: other) == target { other.canManageBots = false }
        bot.canManageBots = true; objectWillChange.send(); save()
    }

    /// One-time: the bot bound to `grok-jarvis` becomes its connection's manager unless that connection already has one.
    func migrateManagerRole() {
        guard !defaults.bool(forKey: Self.managerMigrationKey) else { return }
        defaults.set(true, forKey: Self.managerMigrationKey)
        guard let jarvis = bots.first(where: { $0.backend == .hermes && $0.hermesProfile == "grok-jarvis" && !$0.isReadOnlyArchive }),
              manager(for: jarvis) == nil else { return }
        jarvis.canManageBots = true; save()
    }

    // MARK: On demand

    /// The manager text for this bot (its profile, or its agent id on OpenClaw), placeholders filled; nil when the
    /// resource is missing. P31 C: for Hermes the full text, the core and every recipe file.
    func managerText(for bot: Bot) -> String? {
        if bot.backend == .openClaw {
            return (managerTemplateOverride ?? Self.cachedOpenClawTemplate).map { BotManagerText.filled($0, managerAgent: bot.openClaw?.agentID ?? "") }
        }
        return (managerTemplateOverride ?? Self.cachedTemplate).map { BotManagerText.filled($0, managerProfile: bot.hermesProfile ?? "default") }
    }

    /// The manager text for this turn: only on a management turn of the manager's main chat (an intent match, a menu
    /// request, or a follow-up while the exchange is open); nil otherwise. The backend decides where it goes (P26 D3).
    /// P27 (Hermes managers only): an Install press sends its own instructions instead; once the manager's
    /// `swarmhub-manager` skill is recorded at any version (P31 C: an outdated one too; its Update banner handles the
    /// upgrade), a management turn carries a one-line pointer to it; only a manager without the skill gets the full text.
    /// OpenClaw managers keep the full text (P27 D8).
    func managementText(for bot: Bot, text: String, conversation: any Conversation) -> String? {
        guard isManager(bot), conversation === bot else { return nil }
        if bot.backend == .hermes, let install = pendingSkillInstalls.removeValue(forKey: bot.id) {
            managementExchanges[bot.id] = ManagementExchange(openedAt: now())
            return install.instructions
        }
        let decision = ManagementExchange.decide(text: text, exchange: managementExchanges[bot.id], now: now())
        managementExchanges[bot.id] = decision.next
        guard decision.attach else { return nil }
        if bot.backend == .hermes, let recipe = decision.next?.recipe { return recipe }
        if bot.backend == .hermes, let skill = skills(for: bot).first(where: { $0.name == SkillLibrary.managerSkill }), skillState(skill, for: bot) != .missing {
            return Self.skillPointer
        }
        return managerText(for: bot)
    }

    /// Opens a management exchange in the manager's chat and fills its composer (or sends at once when `send`).
    func startManagement(_ action: ManageBotsAction, manager: Bot, target: String? = nil, send sendNow: Bool = false) {
        guard isManager(manager) else { return }
        if action == .changeSubAgentModel {
            guard manager.backend == .hermes else { return }
            subAgentModelRequest = SubAgentModelRequest(managerID: manager.id, profile: target); return
        }
        managementExchanges[manager.id] = ManagementExchange(openedAt: now(), awaitingOpening: true)
        open(manager); openThreadID = nil
        let request = action.request(bot: target)
        if sendNow, isIdle, send(text: request) { return }
        composerFill = ComposerFill(botID: manager.id, text: request)
    }

    // MARK: swarmhub blocks

    /// Applies the last swarmhub block of a finished manager reply; any block closes the exchange.
    func handleManagerReply(_ reply: ChatMessage, from bot: Bot, in conversation: any Conversation) {
        guard isManager(bot), conversation === bot, let ops = SwarmhubBlock.ops(in: reply.content) else { return }
        managementExchanges[bot.id] = nil
        guard !ops.isEmpty else { return }
        Task { for op in ops { await apply(op, manager: bot) } }
    }

    /// The bot bound to `profile` (an OpenClaw manager: agent id on its Gateway) on the manager's connection, the manager
    /// itself included.
    func boundBot(_ profile: String, manager: Bot) -> Bot? {
        if manager.backend == .openClaw { return boundOpenClawBot(profile, manager: manager) }
        let target = connection(of: manager)
        return bots.first { $0.backend == .hermes && ($0.hermesProfile ?? "default") == profile && !$0.isReadOnlyArchive && connection(of: $0) == target }
    }

    func apply(_ op: SwarmhubOp, manager: Bot) async {
        switch op {
        case .botCreated(let name, let description, let avatar):
            await createBot(name: name, description: description, avatar: avatar, manager: manager)
        case .avatar(let name, let mark):
            guard let bot = boundBot(name, manager: manager) else { return }
            bot.avatarMark = AvatarLook.effectiveMark(shape: mark.shape, colour: mark.colour, seed: bot.avatarSeed); bot.avatarMarkMigrated = false
        case .description(let name, let description):
            boundBot(name, manager: manager)?.botDescription = description
        case .instructionsChanged(let name):
            guard let bot = boundBot(name, manager: manager) else { return }
            var known = bot.boxInstructions ?? BoxInstructions(); known.stale = true; bot.boxInstructions = known
        case .instructions(let name, let text):
            boundBot(name, manager: manager)?.boxInstructions = BoxInstructions(text: text, fetchedAt: now())
        case .botRetired(let name):
            guard let bot = boundBot(name, manager: manager), bot.id != manager.id else { return }
            bot.retiredOnBox = true; setHidden(bot, true)
        case .skillsInstalled(let profile, let installed):
            guard manager.backend == .hermes else { return }
            recordInstalled(installed, profile: profile, manager: manager)
            recordImportedInstalled(installed, profile: profile, manager: manager)
        case .bots(let listed) where manager.backend == .hermes && listed.contains(where: { $0.hasKey != nil }):
            // P35: "List every bot" (has_key per profile): add what answers, list the rest under "not connected".
            await absorbListed(listed, manager: manager)
        case .botsAdopted(let results):
            guard manager.backend == .hermes else { return }
            await finishAdoption(results, manager: manager)
        case .keyRestored(let name, let ok):
            guard manager.backend == .hermes else { return }
            finishRestore(name, ok: ok, manager: manager)
        case .accounts:
            // P31 C: also when Konrad asks the manager in its chat; the Accounts sheet shows it.
            guard manager.backend == .hermes else { return }
            codingAccounts[connection(of: manager), default: AccountsState()].absorb([op], at: now())
        case .report:
            // P36: from any bot's reply (`handleReportOps`), the manager's included.
            return
        case .boxReports, .reportsClosed:
            guard manager.backend == .hermes else { return }
            absorbReportOps([op], connection: connection(of: manager))
        case .models, .boxCapacity:
            // P31 D+E: from SwarmHub's quiet checks, a requested change's reply, or Konrad asking in the chat.
            guard manager.backend == .hermes else { return }
            absorbBoxReadings([op], connection: connection(of: manager))
        case .loginLink, .loginDone:
            // Only from the Accounts sheet's own quiet turns: a link in a chat reply is never shown as a login page.
            return
        case .bots(let listed):
            let skipsDefault = manager.backend == .hermes
            botOffers[manager.id] = listed.filter { !(skipsDefault && $0.name == "default") && boundBot($0.name, manager: manager) == nil }
                .map { BotOffer(name: $0.name, description: $0.description) }
        }
        objectWillChange.send(); save()
    }

    /// Derives the new bot's key, probes its profile and only then stores the key and adds the bot.
    func createBot(name: String, description: String, avatar: AvatarMark?, manager: Bot) async {
        if let existing = boundBot(name, manager: manager) {
            if !description.isEmpty { existing.botDescription = description }
            if let avatar { existing.avatarMark = avatar }
            return
        }
        if manager.backend == .openClaw { return await createOpenClawBot(name: name, description: description, avatar: avatar, manager: manager) }
        switch await probeDerived(name, manager: manager) {
        case .reachable(let key):
            keyStore.setKey(key, for: Self.keyAccount(forProfile: name))
            if manager.hermesBaseURL == nil { namedHermesProfiles += [name] }
            let bot = Bot(name: HermesProfileNaming.botName(forProfile: name), title: "Hermes profile", description: description, backend: .hermes, hermesProfile: name)
            bot.hermesBaseURL = manager.hermesBaseURL
            if let avatar { bot.avatarMark = avatar }
            bots.append(bot); removeSampleBots()
            notice("\(manager.name) created \(bot.name)", in: manager)
        case .rejected, .unreachable:
            notice("Couldn’t reach \(name) yet", in: manager)
        }
    }

    /// "Add" on an offer from a `bots` list: derive + probe; a rejected key falls back to the paste-key flow.
    func addOffered(_ offer: BotOffer, manager: Bot) async {
        if manager.backend == .openClaw { return await addOfferedOpenClaw(offer, manager: manager) }
        setOffer(offer.name, .adding, manager: manager)
        switch await probeDerived(offer.name, manager: manager) {
        case .reachable:
            await createBot(name: offer.name, description: offer.description, avatar: nil, manager: manager)
            botOffers[manager.id]?.removeAll { $0.name == offer.name }
            objectWillChange.send(); save()
        case .rejected: setOffer(offer.name, .needsKey, manager: manager)
        case .unreachable: setOffer(offer.name, .unreachable, manager: manager)
        }
    }

    func setOffer(_ name: String, _ state: BotOffer.State, manager: Bot) {
        guard let index = botOffers[manager.id]?.firstIndex(where: { $0.name == name }) else { return }
        botOffers[manager.id]?[index].state = state
    }

    enum DerivedProbe { case reachable(String), rejected, unreachable }

    /// `GET /p/<name>/v1/models` with the derived key, a few tries over ~10 s; the key never leaves this function except
    /// as the result. 401/403 means the profile exists but does not use the derived key.
    /// P35: `attempts` 1 for discovery's fast path (no retries); the default retries cover a just-written key.
    func probeDerived(_ name: String, manager: Bot, attempts: Int? = nil) async -> DerivedProbe {
        await probeDerived(name, managerKey: keyStore.key(for: Self.keyAccount(forProfile: manager.hermesProfile ?? "default")),
                           baseURL: manager.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL, attempts: attempts)
    }

    /// The same probe for a manager key and box address that are not saved yet (the setup window's scan).
    func probeDerived(_ name: String, managerKey: String, baseURL address: String, attempts: Int? = nil) async -> DerivedProbe {
        guard !managerKey.isEmpty, HermesKeyPaste.isValidProfileName(name), name != "default",
              let baseURL = HermesBackend.validatedBaseURL(address) else { return .unreachable }
        let key = BotManagerText.derivedKey(managerKey: managerKey, botName: name)
        let backend = HermesBackend(baseURL: baseURL, apiKey: key, profile: name, session: hermesSession)
        var rejected = false
        for attempt in 0..<max(1, attempts ?? botProbeAttempts) {
            if attempt > 0 { try? await Task.sleep(for: botProbeDelay) }
            do {
                let json = try await backend.jsonRequest(path: "v1/models", timeout: 5)
                if ((json["data"] as? [[String: Any]])?.first?["id"] as? String) == name { return .reachable(key) }
                rejected = false
            } catch BackendError.http(let code, _) where code == 401 || code == 403 { rejected = true }
            catch { rejected = false }
        }
        return rejected ? .rejected : .unreachable
    }

    /// Launch: resolves each Hermes bot's key once (silently). A key the Keychain would only give behind a dialog is
    /// recovered once per launch when the bot's connection has a manager whose key is readable: the P22 derived key,
    /// kept only if `GET /p/<profile>/v1/models` answers 200. Otherwise the bot stays "Re-enter this bot's key".
    func recoverLockedKeys() async {
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive {
            let profile = bot.hermesProfile ?? "default"; let account = Self.keyAccount(forProfile: profile)
            _ = keyStore.key(for: account)
            guard keyStore.needsReentry(account), profile != "default", HermesKeyPaste.isValidProfileName(profile),
                  let manager = manager(for: bot), manager.hermesProfile != profile, keyStore.claimRecovery(account) else { continue }
            let managerKey = keyStore.key(for: Self.keyAccount(forProfile: manager.hermesProfile ?? "default"))
            guard !managerKey.isEmpty,
                  let baseURL = HermesBackend.validatedBaseURL(bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { continue }
            let key = BotManagerText.derivedKey(managerKey: managerKey, botName: profile)
            let backend = HermesBackend(baseURL: baseURL, apiKey: key, profile: profile, session: hermesSession)
            guard let (_, response) = try? await backend.rawRequest(path: "v1/models", timeout: 10),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            keyStore.setKey(key, for: account)
            objectWillChange.send()
        }
    }

    /// A small line in the manager's chat.
    func notice(_ text: String, in bot: Bot) {
        bot.messages.append(ChatMessage(role: .system, content: text)); objectWillChange.send(); save()
    }
}
