import Foundation

extension AppStore {
    func connectorScope(for bot: Bot) -> String {
        "\(connection(of: bot))|\(bot.backend == .openClaw ? bot.openClaw?.agentID ?? "" : bot.hermesProfile ?? "default")"
    }

    func connectorReport(for bot: Bot) -> BotConnectorReport? {
        bot.connectorReport.flatMap { $0.scope == connectorScope(for: bot) ? $0 : nil }
    }

    func recordConnectors(_ rows: [BotConnectorReport.Connector], for bot: Bot) {
        bot.connectorReport = .init(scope: connectorScope(for: bot), checkedAt: now(), connectors: rows)
        objectWillChange.send(); save()
    }

    /// User-requested read only, through this bot's own backend and credentials. No manager fallback or polling.
    func checkConnectors(for bot: Bot) async {
        guard !connectorChecks.contains(bot.id), !bot.isReadOnlyArchive, [.hermes, .openClaw].contains(bot.backend) else { return }
        connectorChecks.insert(bot.id)
        defer { connectorChecks.remove(bot.id) }
        let scope = connectorScope(for: bot)
        let name = bot.backend == .openClaw ? bot.openClaw?.agentID ?? "" : bot.hermesProfile ?? "default"
        var rows: [BotConnectorReport.Connector]?
        if let instructions = BotConnectorCheck.instructions(backend: bot.backend, name: name),
           let backend = try? backend(for: bot),
           let ops = await quietBoxTurn(backend, persona: bot.persona, request: "Check this bot's connector load state for Swarm Hub.", instructions: instructions) {
            rows = ops.compactMap { op in
                if case .connectors(let reportedName, let reportedRows) = op, reportedName == name { return reportedRows }
                return nil
            }.last
        }
        guard connectorScope(for: bot) == scope else { return }
        recordConnectors(rows ?? [.init(name: "defaults", state: .failed,
                                       detail: "Connector check did not return a report. Check the bot's connection and terminal access, then retry.")], for: bot)
    }
}
