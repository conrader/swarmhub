import Foundation

/// P13 model roles: the read-only inputs for Settings → Models, the Overview lines and `--render-snapshot`.
extension AppStore {
    /// Bots that appear in Settings → Models: live Hermes bots, plus OpenClaw bots (greyed, managed there).
    var modelRoleBots: [Bot] { bots.filter { ($0.backend == .hermes || $0.backend == .openClaw) && !$0.isReadOnlyArchive && !$0.isDemo } }

    func modelRolesInput(for bot: Bot) -> ModelRolesModel.Input {
        let server = bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
        let current = currentModel(for: bot)
        let locked = bot.hermesModelLock.map { $0.sessionID == bot.hermesSessionID } ?? false
        let block = catalogBlock(for: bot)
        // Each row sits under its own host; an OpenClaw agent's group is its Gateway's name ("OpenClaw" while unbound).
        return .init(id: bot.id, name: bot.name, server: bot.backend == .openClaw ? gateway(id: bot.openClaw?.gatewayID)?.name ?? "OpenClaw" : URL(string: server)?.host ?? server, profile: bot.hermesProfile ?? "default",
                     isOpenClaw: bot.backend == .openClaw, catalog: modelCatalog(for: bot), canAsk: block?.countsAsAskable ?? true,
                     info: botInfo.info(for: bot.id), settings: modelSettings(for: bot), defaults: modelDefaultsForRoles, current: current, isLocked: locked, hasChat: bot.hermesSessionID != nil)
    }

    func modelSettings(for bot: Bot) -> BotModelSettings? { bot.modelSettings }
    var modelDefaultsForRoles: ModelDefaults? { effectiveModelDefaults }

    func modelRoles() -> ModelRolesModel { ModelRolesModel(modelRoleBots.map(modelRolesInput)) }
    func modelRolesRow(for bot: Bot) -> ModelRolesModel.Row { ModelRolesModel.row(modelRolesInput(for: bot)) }

    /// Settings → Models → Load: capabilities, model options, toolsets and the session row (no skills) for every
    /// bot with a catalog source and a key, at most four at a time, into the shared `BotInfoCache`. GETs only; nothing is saved.
    func loadModelRoles() async {
        let ids = modelRoleBots.filter { catalogBlock(for: $0) == nil }.map(\.id)
        for start in stride(from: 0, to: ids.count, by: 4) {
            let batch = ids[start..<min(start + 4, ids.count)].map { id in
                Task { guard let bot = bots.first(where: { $0.id == id }) else { return }; await loadServerInfo(for: bot, force: true, includeSkills: false) }
            }
            for task in batch { await task.value }
        }
    }

    /// Text for `--render-snapshot`, from the same model the pane draws.
    func modelRolesSummary(for bot: Bot) -> String {
        guard bot.backend == .hermes || bot.backend == .openClaw, !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly else { return "\(bot.name): roles none (not a Hermes bot)" }
        return ModelRolesModel.headlessLine(modelRolesRow(for: bot))
    }
}
