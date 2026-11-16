import Foundation

/// The Herdr workspace connection (`HerdrBackend`): one bridge address and access token for the app, and the
/// template each bot starts its agent from.
extension AppStore {
    func herdrClient() throws -> HerdrClient {
        guard let baseURL = HerdrClient.validatedBaseURL(defaults.string(forKey: HerdrBackend.urlKey) ?? HerdrBackend.defaultURL) else { throw HerdrClient.Failure.invalidURL }
        // A development launch outside the person's own home has no Keychain; it may pass the token in instead.
        let saved = keyStore.key(for: HerdrBackend.keyAccount)
        let token = saved.isEmpty ? ProcessInfo.processInfo.environment[HerdrBackend.tokenEnvironment] ?? "" : saved
        if token.isEmpty { throw BackendError.unavailable(HerdrBackend.missingToken) }
        return HerdrClient(baseURL: baseURL, token: token)
    }

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

    func herdrBackend(for bot: Bot) throws -> HerdrBackend {
        var backend = HerdrBackend(client: try herdrClient(), botName: bot.name, botID: bot.id, template: herdrTemplate(for: bot), model: herdrModel(for: bot), instructions: bot.persona)
        backend.steers = herdrSteers(bot)
        return backend
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

    /// The model a starter bot begins on: the current Sonnet for Claude Code, GPT-6.1 Sol for Codex. Nil for any other
    /// agent program, or when the template's own list does not offer it.
    static func starterModel(harness: String?, offered: [HerdrClient.Template.Model]) -> String? {
        let wanted: String? = switch harness { case "Claude Code": "sonnet"; case "Codex": "gpt-6.1-sol"; default: nil }
        guard let wanted, offered.isEmpty || offered.contains(where: { $0.id == wanted }) else { return nil }
        return wanted
    }

    /// One ready-to-use bot per agent program the Herdr server can start (Claude, Codex), each on its starter model.
    /// A program that already has a Herdr bot is skipped. Returns the names it added.
    func addHerdrStarterBots() async throws -> [String] {
        let client = try herdrClient()
        let usable = try await client.workspace().templates.filter { $0.error == nil }
        let taken = Set(bots.filter { $0.backend == .herdr }.compactMap { herdrTemplate(for: $0) })
        var added: [String] = []
        for (harness, name, title) in [("Claude Code", "Claude", "Claude Code on Herdr"), ("Codex", "Codex", "Codex on Herdr")] {
            guard let template = usable.first(where: { $0.runtime?.harness == harness }), !taken.contains(template.name),
                  !bots.contains(where: { $0.backend == .herdr && $0.name == name }) else { continue }
            let offered = (try? await client.models(for: template)) ?? template.models ?? []
            addBot(name: name, persona: Bot.defaultPersona, backend: .herdr, avatarName: nil)
            guard let bot = bots.last(where: { $0.backend == .herdr && $0.name == name }) else { continue }
            bot.title = title
            setHerdrTemplate(template.name, for: bot)
            setHerdrModel(Self.starterModel(harness: harness, offered: offered) ?? "", for: bot)
            added.append(name)
        }
        if !added.isEmpty { save() }
        return added
    }

    /// The templates Herdr Core can start right now, for the pickers.
    func herdrTemplates() async throws -> [HerdrClient.Template] {
        try await herdrClient().workspace().templates.filter { $0.error == nil }
    }
}
