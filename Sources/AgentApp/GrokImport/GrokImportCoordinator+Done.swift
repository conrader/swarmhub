import Foundation

/// The Done step (briefs/P10.md P10d 2): "Get these bots talking". Counts are read back from the store and the archive
/// files, and each bot's state is measured, never assumed: Live only when its key is present and
/// `GET /p/<profile>/v1/models` names the profile.
extension GrokImportCoordinator {
    /// Rebuilds the outcome rows from what the store holds now, then measures each bot's connection.
    func refreshOutcomes() async {
        outcomes = committedRows.map { row in
            let bot = store.bots.first { $0.grokSourceID == row.sourceID }
            let group = store.groups.first { $0.grokSourceID == row.sourceID }
            let ownerID = bot?.id ?? group?.id
            return GrokImportOutcome(
                id: row.sourceID, botID: ownerID, name: bot?.name ?? group?.name ?? row.name, isGroup: row.isGroup,
                profile: bot?.hermesProfile,
                archiveLines: ownerID.flatMap { store.grokHistory.lineCountOnDisk(for: $0) } ?? 0,
                connection: row.isGroup ? .historyOnly : .checking, row: row)
        }
        await measureConnections()
    }

    func measureConnections() async {
        for index in outcomes.indices where !outcomes[index].isGroup {
            outcomes[index].connection = .checking
            guard let bot = store.bots.first(where: { $0.grokSourceID == outcomes[index].id }) else {
                outcomes[index].connection = .historyOnly
                continue
            }
            outcomes[index].profile = bot.hermesProfile
            outcomes[index].connection = await Self.connection(of: bot, store: store)
        }
    }

    /// The bots on the Done step, in import order (groups included, for the coverage details).
    var botOutcomes: [GrokImportOutcome] { outcomes.filter { !$0.isGroup } }
    var needsKeyProfiles: [String] { botOutcomes.filter { $0.connection == .needsKey }.compactMap(\.profile) }
    /// `<profile>=` lines for the Needs-key bots, to prefill "Add keys…".
    var addKeysPrefill: String { needsKeyProfiles.map { "\($0)=" }.joined(separator: "\n") }

    /// "Add keys…": the "Add bots from box" flow, then measure again.
    func addKeys(_ text: String) async -> [HermesBotAddResult] {
        let results = await store.addBotsFromBox(text)
        await refreshOutcomes()
        return results
    }

    /// "Check again": bind the bots that still have no profile (fill-only), then measure again.
    func checkConnectionsAgain() async {
        store.bindUnboundGrokBots()
        await refreshOutcomes()
    }

    /// One read-only probe per bot. A key is looked for by attributes first, so a missing one never reads the Keychain.
    static func connection(of bot: Bot, store: AppStore) async -> GrokConnection {
        guard bot.backend == .hermes, let profile = bot.hermesProfile, !bot.isGrokHistoryOnly else { return .historyOnly }
        if profile != "default", !store.keyStore.hasKey(for: AppStore.keyAccount(forProfile: profile)) { return .needsKey }
        let backend: HermesBackend
        do {
            guard let built = try store.backend(for: bot) as? HermesBackend else { return .unreachable }
            backend = built
        } catch { return store.prefixIgnoredHermesProfiles.contains(profile) ? .profileNotOnServer : .unreachable }
        if backend.apiKey.isEmpty, profile != "default" { return .needsKey }
        do {
            let models = try await backend.jsonRequest(path: "v1/models")
            guard let id = (models["data"] as? [[String: Any]])?.first?["id"] as? String else { return .profileNotOnServer }
            return HeadlessCommands.modelMatches(id, profile: profile) ? .live : .profileNotOnServer
        } catch BackendError.http(let status, _) {
            switch status {
            case 401, 403: return .needsKey
            case 404: return .profileNotOnServer
            default: return .unreachable
            }
        } catch { return .unreachable }
    }
}
