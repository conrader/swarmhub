import Foundation

extension AppStore {
    func chatSummaryURL(_ bot: UUID) -> URL {
        grokHistory.directory.appending(path: "\(bot.uuidString.lowercased()).chat-summary.json")
    }

    func summarizeAndStartFresh(_ bot: Bot) async throws {
        let changed = BackendError.unavailable("The chat changed while preparing its summary. Try again when it is idle.")
        guard bots.contains(bot), bot.backend == .herdr, !bot.isDemo, !bot.isReadOnlyArchive,
              !herdrBotIsBusy(bot), summarizingChats.insert(bot.id).inserted else { throw changed }
        defer { summarizingChats.remove(bot.id) }

        await herdrWarming[bot.id]?.value
        let backend = try herdrBackend(for: bot), server = herdrServer(for: bot)
        let workspace = try await backend.client.workspace()
        guard let core = workspace.core else { throw HerdrClient.Failure.noTemplate }
        let agent = backend.client.liveAgent(named: backend.agentName, in: workspace)
        func checkIdle(_ live: HerdrClient.Workspace) throws {
            let current = backend.client.liveAgent(named: backend.agentName, in: live)
            guard bots.contains(bot), herdrServer(for: bot) == server, !herdrBotIsBusy(bot),
                  live.core == core, current?.ref == agent?.ref else { throw changed }
            if let current, !current.isIdleForRollover || herdrAgentIsBusy(current, in: live.agents) { throw changed }
        }
        func latestEvent() async throws -> Int? {
            guard let agent else { return nil }
            return try await backend.client.history(core: core, address: agent.address, createdMs: agent.createdMs).map(\.id).max()
        }
        try checkIdle(workspace)
        let previousEvent = try await latestEvent()
        let lines = herdrCarryLines(of: bot), name = bot.name
        guard let last = lines.last else { throw BackendError.unavailable("This chat has no completed exchanges to summarize.") }
        let parts = await Task.detached(priority: .userInitiated) {
            GrokHandoff.parts(of: GrokHandoff.Transcript(lines).spoken, botName: name)
        }.value
        guard let parts else { throw HerdrClient.Failure.silent }
        // The summary agent has its own identity and can run alongside the person's chat.
        let written = try await backend.client.summarise(parts.files, name: HerdrClient.compactorName(for: UUID()),
                                                         template: backend.template, model: backend.model, limit: grokHandoffs.askedLimit)
        let cache = GrokHandoffCache(summary: written, from: parts.from, through: parts.through, messages: parts.messages,
                                     template: backend.template ?? "", model: backend.model ?? "", madeAt: now())
        guard !cache.summary.isEmpty else { throw HerdrClient.Failure.silent }
        guard try await latestEvent() == previousEvent else { throw changed }
        let live = try await backend.client.workspace()
        try checkIdle(live)
        guard herdrCarryLines(of: bot) == lines else { throw changed }
        // Save before ending the exact launch. A lost end receipt cannot lose the handoff,
        // and a session which is still alive skips its own summary.
        try cache.save(to: chatSummaryURL(bot.id), directory: grokHistory.directory)
        let old = agent.map { HerdrAgentLaunch(server: server.id, core: core, address: $0.address, createdMs: $0.createdMs) }
        setHerdrCarryOver(HerdrCarryOver(old: old, at: now(), summaryEndsAt: last.id), for: bot)
        if let agent { try await backend.client.endIfIdle(agent, core: core, workspace: live) }
        herdrReadiness[bot.id] = nil
        if launchWorkEnabled { _ = warmHerdrAgent(for: bot) }
    }
}
