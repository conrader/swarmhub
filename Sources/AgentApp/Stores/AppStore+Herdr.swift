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
        HerdrBackend(client: try herdrClient(), botName: bot.name, botID: bot.id, template: herdrTemplate(for: bot), model: herdrModel(for: bot), instructions: bot.persona)
    }

    /// Ends the bot's running agent, so its next message starts a fresh one on the chosen runtime and model.
    /// Returns whether an agent was running. The chat stays; the agent's own memory of it does not.
    func restartHerdrAgent(for bot: Bot) async throws -> Bool {
        let backend = try herdrBackend(for: bot)
        guard let agent = backend.client.liveAgent(named: backend.agentName, in: try await backend.client.workspace()) else { return false }
        try await backend.client.end(agent)
        return true
    }

    /// The templates Herdr Core can start right now, for the pickers.
    func herdrTemplates() async throws -> [HerdrClient.Template] {
        try await herdrClient().workspace().templates.filter { $0.error == nil }
    }
}
