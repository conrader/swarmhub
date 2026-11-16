import Foundation

/// The Herdr workspace connection (`HerdrBackend`): one bridge address and access token for the app, and the
/// template each bot starts its agent from.
extension AppStore {
    func herdrClient() throws -> HerdrClient {
        guard let baseURL = HerdrClient.validatedBaseURL(defaults.string(forKey: HerdrBackend.urlKey) ?? HerdrBackend.defaultURL) else { throw HerdrClient.Failure.invalidURL }
        let token = keyStore.key(for: HerdrBackend.keyAccount)
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

    /// The templates Herdr Core can start right now, for the pickers.
    func herdrTemplates() async throws -> [HerdrClient.Template] {
        try await herdrClient().workspace().templates.filter { $0.error == nil }
    }
}
