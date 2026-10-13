import Foundation

extension AppStore {
    /// Loads (or with `force`, refreshes) what the bot's Hermes profile reports. No-op for non-Hermes bots.
    func loadServerInfo(for bot: Bot, force: Bool = false) async {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive else { return }
        do {
            guard let backend = try backend(for: bot) as? HermesBackend else { return }
            await botInfo.load(botID: bot.id, sessionID: bot.hermesSessionID, using: backend, force: force)
        } catch {
            botInfo.setUnavailable(botID: bot.id, reason: error.localizedDescription)
        }
    }

    func currentModel(for bot: Bot) -> CurrentModel? {
        let info = botInfo.info(for: bot.id)
        var aliases: Set<String> = ["hermes-agent"]
        if let alias = info?.capabilities?.model { aliases.insert(alias) }
        if let profile = bot.hermesProfile { aliases.insert(profile) }
        return BotInfoCache.currentModel(lock: bot.hermesModelLock, sessionID: bot.hermesSessionID, sessionModel: info?.sessionModel, aliases: aliases, options: info?.modelOptions.value)
    }

    /// Locks the bot's current Hermes session to `provider`/`model` via `POST /api/sessions/{id}/model`.
    func switchModel(for bot: Bot, provider: String, model: String) async {
        guard let sessionID = bot.hermesSessionID else { botInfo.finishSwitch(botID: bot.id, error: "Send a message first; the model is set per chat session."); return }
        guard botInfo.info(for: bot.id)?.canLockSessionModel == true else { botInfo.finishSwitch(botID: bot.id, error: "This server cannot switch a chat's model."); return }
        botInfo.beginSwitch(botID: bot.id)
        do {
            guard let backend = try backend(for: bot) as? HermesBackend else { throw BackendError.unavailable("This bot is not on Hermes.") }
            bot.hermesModelLock = try await backend.lockSessionModel(sessionID: sessionID, provider: provider, model: model)
            save(); botInfo.finishSwitch(botID: bot.id, error: nil)
        } catch BackendError.http(409, _) {
            botInfo.finishSwitch(botID: bot.id, error: "Hermes cannot route \(model) for this chat and will not fall back to the default.")
        } catch {
            botInfo.finishSwitch(botID: bot.id, error: error.localizedDescription)
        }
    }
}

extension BotInfoCache {
    func setUnavailable(botID: UUID, reason: String) {
        var info = BotServerInfo(); info.isRefreshing = false
        info.skills = .failed(reason); info.toolsets = .failed(reason); info.modelOptions = .unavailable(reason)
        replace(botID: botID, with: info)
    }
}
