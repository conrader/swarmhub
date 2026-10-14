import Foundation

/// P17: the one accessor every model surface reads. A bot that cannot be asked gets its reason with no request.
extension AppStore {
    /// Why a bot's models cannot be read, before any request; nil when they can.
    enum CatalogBlock: Equatable {
        case archive, noBackend, historyOnly(String), multiplexOff(String), openClawStub, noKey
        var text: String {
            switch self {
            case .archive: ModelCatalog.archive
            case .noBackend: ModelCatalog.noBackend
            case .historyOnly(let text), .multiplexOff(let text): text
            case .openClawStub: ModelRoleReason.openClaw.text
            case .noKey: ModelCatalog.noKey
            }
        }
        /// Counted among the agents Settings could ask (it has a backend, it only lacks a key or routing).
        var countsAsAskable: Bool { self == .noKey || { if case .multiplexOff = self { true } else { false } }() }
    }

    func catalogBlock(for bot: Bot) -> CatalogBlock? {
        if bot.isReadOnlyArchive { return .archive }
        if bot.isDemo || bot.backend == .mock { return .noBackend }
        if bot.isGrokHistoryOnly { return .historyOnly("History only — not connected to a Hermes profile yet.") }
        if needsKey(bot) { return .noKey }
        let backend: any AgentBackend
        do { backend = try self.backend(for: bot) } catch { return .multiplexOff(error.localizedDescription) }
        if backend is HermesBackend || backend is ModelCatalogProviding { return nil }
        return bot.backend == .openClaw ? .openClawStub : .noBackend
    }

    func modelCatalog(for bot: Bot) -> Loadable<ModelCatalog> {
        if let block = catalogBlock(for: bot) { return .unavailable(block.text) }
        return botInfo.info(for: bot.id)?.catalog(profile: bot.hermesProfile ?? "default") ?? .loading
    }

    /// The editor's load (P17 item 3): its GETs without skills, only for a saved agent whose pending Backend is the saved one.
    func loadEditorModels(for bot: Bot?, pendingBackend: BackendKind, force: Bool = false) async {
        guard let bot, pendingBackend == bot.backend else { return }
        await loadServerInfo(for: bot, force: force, includeSkills: false)
    }

    /// The editor line for `--render-snapshot`: names and counts only.
    func editorModelsSummary(for bot: Bot) -> String {
        guard case .loaded(let catalog) = modelCatalog(for: bot) else {
            let reason: String
            switch modelCatalog(for: bot) {
            case .unavailable(let text), .failed(let text): reason = text
            default: reason = "not loaded"
            }
            return "\(bot.name): editor models no list (\(reason))"
        }
        let check = ModelPolicy.check(modelDefaults.conversation, catalog: catalog)?.word ?? "none"
        return "\(bot.name): editor models \(catalog.place), \(catalog.detail); agent default \(catalog.agentDefault?.model ?? "unknown"); \(AppConstants.name) default \(check); \(catalog.suppliers.count) suppliers"
    }
}
