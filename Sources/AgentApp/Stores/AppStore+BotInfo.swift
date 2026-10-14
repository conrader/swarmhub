import Foundation

extension AppStore {
    /// Loads what the bot's Hermes profile reports when the entry is missing, stale (`BotInfoCache.maxAge`), failed,
    /// or was read for another profile or session; `force` always refreshes. A backend that supplies its own catalog
    /// (`ModelCatalogProviding`) loads that; any other bot is a no-op. A Hermes bot without its key sends nothing (P17).
    func loadServerInfo(for bot: Bot, force: Bool = false, includeSkills: Bool = true) async {
        guard !bot.isReadOnlyArchive, bot.backend != .mock else { return }
        if bot.backend == .hermes, !bot.isGrokHistoryOnly, needsKey(bot) { botInfo.setUnavailable(botID: bot.id, reason: ModelCatalog.noKey, failed: false); return }
        do {
            let backend = try backend(for: bot)
            if let hermes = backend as? HermesBackend {
                await botInfo.load(botID: bot.id, sessionID: bot.hermesSessionID, using: hermes, force: force, includeSkills: includeSkills)
            } else if let provider = backend as? ModelCatalogProviding {
                await botInfo.loadCatalog(botID: bot.id, sessionID: bot.hermesSessionID, using: provider, force: force)
            }
        } catch {
            if bot.backend == .hermes { botInfo.setUnavailable(botID: bot.id, reason: error.localizedDescription) }
        }
    }

    /// The gateway's virtual model names for this bot: a session row carrying one has no concrete model yet.
    func modelAliases(for bot: Bot) -> Set<String> {
        var aliases: Set<String> = ["hermes-agent"]
        if let alias = botInfo.info(for: bot.id)?.capabilities?.model { aliases.insert(alias) }
        if let profile = bot.hermesProfile { aliases.insert(profile) }
        return aliases
    }

    func currentModel(for bot: Bot) -> CurrentModel? {
        let info = botInfo.info(for: bot.id)
        let aliases = modelAliases(for: bot)
        let sessionModel = info?.sessionModelSessionID == bot.hermesSessionID ? info?.sessionModel : nil
        return BotInfoCache.currentModel(lock: bot.hermesModelLock, sessionID: bot.hermesSessionID, sessionModel: sessionModel, aliases: aliases, catalog: modelCatalog(for: bot).value)
    }

    func modelPicker(for bot: Bot) -> ModelPickerModel {
        let profile = bot.hermesProfile ?? "default"
        if let block = catalogBlock(for: bot) { return ModelPickerModel(reason: block.text, profile: profile) }
        return ModelPickerModel(info: botInfo.info(for: bot.id), current: currentModel(for: bot), sessionID: bot.hermesSessionID, profile: profile)
    }

    /// Locks the bot's current Hermes session to `provider`/`model` via `POST /api/sessions/{id}/model`, then reads
    /// the session back. Only a model the loaded list offers under that supplier, and not disabled, is sent.
    func switchModel(for bot: Bot, provider: String, model: String, origin: LockOrigin? = nil) async {
        guard let sessionID = bot.hermesSessionID else { botInfo.finishSwitch(botID: bot.id, error: "Send a message first; the model is set per chat session."); return }
        guard botInfo.info(for: bot.id)?.canLockSessionModel == true else { botInfo.finishSwitch(botID: bot.id, error: "This server cannot switch a chat's model."); return }
        let picker = modelPicker(for: bot)
        // A list kept from before a failed refresh (P17) is shown, never switched from: Retry first.
        guard botInfo.info(for: bot.id)?.refreshError == nil, let item = picker.item(provider: provider, model: model), item.disabledReason == nil else {
            let supplier = picker.groups.first { $0.slug == provider }?.name ?? provider
            let why = picker.item(provider: provider, model: model)?.disabledReason.map { " (\($0))" } ?? ""
            botInfo.finishSwitch(botID: bot.id, error: "The box does not offer \(model) from \(supplier) right now\(why); nothing was sent."); return
        }
        botInfo.beginSwitch(botID: bot.id)
        var key = ""
        do {
            guard let backend = try backend(for: bot) as? HermesBackend else { throw BackendError.unavailable("This bot is not on Hermes.") }
            key = backend.apiKey
            try await lockModel(backend, bot: bot, sessionID: sessionID, provider: item.supplierSlug, model: item.model, origin: origin)
            if botInfo.info(for: bot.id)?.capabilities?.features["session_resources"] != false,
               let readBack = try? await backend.sessionModel(sessionID: sessionID), bot.hermesSessionID == sessionID {
                botInfo.setSessionModel(botID: bot.id, sessionID: sessionID, model: readBack)
            }
            botInfo.finishSwitch(botID: bot.id, error: nil)
        } catch BackendError.http(409, _) {
            botInfo.finishSwitch(botID: bot.id, error: "Hermes cannot route \(model) for this chat and will not fall back to the default.")
        } catch {
            botInfo.finishSwitch(botID: bot.id, error: BotInfoCache.describe(error, key: key))
        }
    }

    /// Text for `--render-snapshot`, built from the same `ModelPickerModel` the Overview draws.
    func modelMenuSummary(for bot: Bot) -> String {
        guard bot.backend == .hermes || bot.backend == .openClaw, !bot.isReadOnlyArchive else { return "\(bot.name): model menu none (not a Hermes bot)" }
        return modelPicker(for: bot).headlessLine(botName: bot.name)
    }
}

extension BotInfoCache {
    /// `failed: false` (no key): every section reads the reason as unavailable, with no Retry.
    func setUnavailable(botID: UUID, reason: String, failed: Bool = true) {
        var info = BotServerInfo(); info.isRefreshing = false; info.lastLoadFailed = failed
        info.skills = failed ? .failed(reason) : .unavailable(reason); info.toolsets = failed ? .failed(reason) : .unavailable(reason); info.modelOptions = .unavailable(reason)
        replace(botID: botID, with: info)
    }
}
