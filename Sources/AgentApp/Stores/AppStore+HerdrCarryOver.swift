import Foundation

/// A bot whose agent program or model was changed carries on: the agent program keeps a conversation itself, so
/// an agent that starts fresh on the new choice knows nothing of what was said. When a change is applied
/// (`AppStore+HerdrModels.swift`) the Mac notes for each changed bot which agent was running then. That agent has
/// the conversation and is never handed it; the next agent the bot starts is another launch, and before the
/// person's message it reads the bot's chat so far, once: the recent part word for word, a summary of the older
/// part when the chat is long, and the whole of it as a file to search. It travels the way an imported
/// conversation does (`HerdrHandoff`, `HerdrBackend.handOver`), so it never holds a message back.
/// A bot that is handed an imported conversation keeps that handoff instead. Details → New conversation starts a
/// bot with empty context as it always did, and takes the note away.
extension AppStore {
    /// What the Mac remembers while a bot's next agent is to read its chat.
    struct HerdrCarryOver: Codable, Equatable {
        /// The agent that was running when the change was made; nil when the bot had none.
        var old: HerdrAgentLaunch?
        /// The launch the handoff last failed for, and how often in a row (`HerdrHandoffSource.failures`).
        var failedFor: HerdrAgentLaunch? = nil
        var failures = 0
        var at: Date
        var summaryEndsAt: String? = nil
    }

    static func herdrCarryOverKey(_ botID: UUID) -> String { "herdrCarryOver.\(botID.uuidString.lowercased())" }

    func herdrCarryOver(for bot: Bot) -> HerdrCarryOver? {
        defaults.data(forKey: Self.herdrCarryOverKey(bot.id)).flatMap { try? JSONDecoder().decode(HerdrCarryOver.self, from: $0) }
    }

    func setHerdrCarryOver(_ state: HerdrCarryOver?, for bot: Bot) {
        if state?.summaryEndsAt == nil, herdrCarryOver(for: bot)?.summaryEndsAt != nil {
            try? FileManager.default.removeItem(at: chatSummaryURL(bot.id))
        }
        if let state { defaults.set(try? JSONEncoder().encode(state), forKey: Self.herdrCarryOverKey(bot.id)) }
        else { defaults.removeObject(forKey: Self.herdrCarryOverKey(bot.id)) }
    }

    /// The handoff has ended in the turn that is running (read, or nothing to read): the note goes, and the turn
    /// is followed until it takes steers again.
    private func endHerdrCarryOver(for bot: Bot) {
        setHerdrCarryOver(nil, for: bot)
        if turn(in: bot) != nil { grokHandoffs.carried.insert(bot.id) }
    }

    /// The bot is gone: nothing of this is kept.
    func forgetHerdrCarryOver(_ botID: UUID) {
        try? FileManager.default.removeItem(at: chatSummaryURL(botID))
        defaults.removeObject(forKey: Self.herdrCarryOverKey(botID))
        defaults.removeObject(forKey: "herdr.confirmed.\(botID)")
        clearModelSwitch(botID)
        clearAutoSwitch(botID)
        defaults.removeObject(forKey: Self.herdrMoveSkipsCarryKey(botID))
        latestHerdrMoves[botID] = nil
        grokHandoffs.carried.remove(botID)
    }

    /// The bot's next agent can be handed its chat: it runs on a server, and no imported conversation is handed
    /// over instead. Whether anything was said is looked at when the agent starts, not now: a bot in its first
    /// answer has a chat by then.
    func herdrCarryApplies(to bot: Bot) -> Bool {
        bot.backend == .herdr && !bot.isReadOnlyArchive && !bot.isDemo && !grokHandoffIsOn(for: bot)
    }

    /// The agents running for the server's bots right now, by bot; nil when the server could not be read.
    func herdrRunningLaunches(on server: HerdrServer) async -> [UUID: HerdrAgentLaunch]? {
        guard let client = try? herdrClient(for: server), let current = try? await client.workspace(), let core = current.core else { return nil }
        var found: [UUID: HerdrAgentLaunch] = [:]
        for bot in herdrBots(on: server) {
            guard let agent = client.liveAgent(named: HerdrBackend.agentName(botName: bot.name, botID: bot.id), in: current) else { continue }
            found[bot.id] = HerdrAgentLaunch(server: server.id, core: core, address: agent.address, createdMs: agent.createdMs)
        }
        return found
    }

    /// The agent program or model of `changed` was just changed, and `running` are the agents that ran then: each
    /// bot's next agent reads its chat first.
    func armHerdrCarryOver(for changed: [Bot], running: [UUID: HerdrAgentLaunch]) {
        for bot in changed where herdrCarryApplies(to: bot) {
            setHerdrCarryOver(HerdrCarryOver(old: running[bot.id], at: now(), summaryEndsAt: herdrCarryOver(for: bot)?.summaryEndsAt), for: bot)
        }
    }

    func recoverVaultSession(for bot: Bot, server: HerdrServer, core: String, target: HerdrClient.AgentRef) async throws {
        let client = try herdrClient(for: server)
        let workspace = try await client.workspace()
        let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
        guard bots.contains(bot), !bot.isDemo, !bot.isReadOnlyArchive, herdrServer(for: bot) == server,
              workspace.core == core, let agent = client.liveAgent(named: name, in: workspace),
              agent.ref == target, agent.parent == nil, agent.vaultSessionStale == true, agent.isIdleForRollover,
              !herdrBotIsBusy(bot), !herdrAgentIsBusy(agent, in: workspace.agents) else { throw HerdrMoveError.undoBusy }
        let launch = HerdrAgentLaunch(server: server.id, core: core, address: target.address, createdMs: target.createdMs)
        armHerdrCarryOver(for: [bot], running: [bot.id: launch])
        try await client.recoverVaultSession(core: core, bot: bot.id, target: target)
        guard bots.contains(bot), herdrServer(for: bot) == server else { return }
        herdrReadiness[bot.id] = nil
        if launchWorkEnabled { await warmHerdrAgent(for: bot)?.value }
        await refreshHerdrAgentReading(for: bot)
    }

    // MARK: The chat as a conversation to hand over

    /// What the person and the bot said in the bot's chat, oldest first, numbered from 1. Left out: the app's own
    /// lines, tool rows, a reply that is being written, and the messages the bot has not answered yet (the one being
    /// sent now, and any waiting behind it): those reach the agent by themselves, after the handoff.
    func herdrCarryLines(of bot: Bot) -> [ArchivedMessage] {
        var rows = bot.messages.filter { message in
            (message.role == .user || message.role == .assistant) && !message.isStreaming && message.presentation == .text && !AppOnlyLine.isAppOnly(message)
        }
        while let last = rows.last, last.role == .user, last.metadata[PromotedHelper.rowKey] == nil { rows.removeLast() }
        var lines: [ArchivedMessage] = []
        for (index, message) in rows.enumerated() {
            let text = message.role == .assistant ? SwarmhubBlock.visibleText(message.content) : message.content
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // A message the app passed on for another bot is not the person's: it reads as "Infra → Legal".
            let helperAssignment = message.role == .user && message.metadata[PromotedHelper.rowKey] != nil
            let passedOn = helperAssignment || message.role == .user && isAppWritten(message)
            let parentName = helperAssignment ? bot.promotedHelper.flatMap { source in bots.first { $0.id == source.parentID }?.name } : nil
            let sender = passedOn ? (parentName ?? herdrPassedOnRow(message)?.sender?.name ?? AppConstants.name) : nil
            lines.append(ArchivedMessage(id: message.id.uuidString.lowercased(), seq: Int64(index + 1), role: message.role == .user ? "user" : "assistant",
                                         author: sender, text: text, timestamp: message.createdAt, hidden: false,
                                         channel: passedOn ? "agent" : "chat", to: passedOn ? bot.name : nil))
        }
        return lines
    }

    // MARK: A turn

    /// What the bot's backend hands over before a message (`HerdrBackend.handoff`); nil leaves the turn as it always was.
    func herdrCarrySource(for bot: Bot) -> HerdrHandoffSource? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive, !bot.isDemo, let state = herdrCarryOver(for: bot) else { return nil }
        let id = bot.id
        let handoffID = bot.promotedHelper?.handoffID
        var source = HerdrHandoffSource(lead: GrokHandoff.lead(for: handoffID ?? id, origin: .ownChat), prepare: { [weak self] status in await self?.herdrCarryHandoff(for: id, status: status) })
        // The agent that ran before the change holds the conversation itself.
        source.read = state.old
        source.failedFor = state.failedFor
        source.failures = state.failures
        source.delivered = { [weak self] receipt in Task { @MainActor in self?.herdrCarriedOver(receipt, botID: id, handoffID: handoffID) } }
        source.failed = { [weak self] failure in Task { @MainActor in self?.herdrCarryFailed(failure, botID: id, handoffID: handoffID) } }
        return source
    }

    /// Prepare the new session’s context off the main actor. An explicit restart reads the saved
    /// summary even after quitting the app. Newer exchanges and the searchable transcript travel with it.
    func herdrCarryHandoff(for botID: UUID, status: @escaping @Sendable (HerdrTurnStatus) -> Void) async -> HerdrHandoff? {
        guard let bot = bots.first(where: { $0.id == botID }), let state = herdrCarryOver(for: bot) else { return nil }
        let lines = herdrCarryLines(of: bot), name = bot.name
        guard !lines.isEmpty else { endHerdrCarryOver(for: bot); return nil }
        let contextID = bot.promotedHelper?.handoffID ?? botID
        let url = chatSummaryURL(botID)
        return await Task.detached(priority: .userInitiated) {
            let transcript = GrokHandoff.Transcript(lines)
            var summary: GrokHandoffCache?
            var plan = GrokHandoff.plan(transcript, botName: name)
            if let last = state.summaryEndsAt,
               let line = transcript.lines.first(where: { $0.id == last }),
               let saved = GrokHandoffCache.load(url), line.seq == saved.through {
                summary = saved
                let spoken = transcript.spoken
                // Preserve the usual size limit if many new messages arrived after the summary.
                let through = max(line.seq, plan.older.last?.seq ?? line.seq)
                plan.older = spoken.filter { $0.seq <= through }
                plan.recent = spoken.filter { $0.seq > through }
            }
            let rendered = GrokHandoff.render(transcript, plan: plan, summary: summary, botName: name, origin: .ownChat)
            return GrokHandoff.package(rendered, archiveID: contextID, origin: .ownChat)
        }.value
    }

    /// A fresh agent has replied to the handoff: it has the chat, so nothing more is handed over until the bot's
    /// program or model changes again. When this turn sent it, the chat says so.
    func herdrCarriedOver(_ receipt: HerdrHandoffReceipt, botID: UUID, handoffID: UUID? = nil) {
        guard let bot = bots.first(where: { $0.id == botID }), bot.promotedHelper?.handoffID == handoffID, herdrCarryOver(for: bot) != nil else { return }
        endHerdrCarryOver(for: bot)
        guard let handoff = receipt.handoff else { return }
        grokChatLine(HerdrCarryCopy.read(bot.name, summarised: handoff.summary != nil, older: handoff.olderMessages, recent: handoff.recentMessages, withFiles: receipt.withFiles), in: bot)
    }

    /// The handoff failed and the person's message went without it: counted for that launch of the agent, and said
    /// in the chat. At `HerdrHandoff.attempts` for one launch the backend no longer tries for it.
    func herdrCarryFailed(_ failure: HerdrHandoffFailure, botID: UUID, handoffID: UUID? = nil) {
        guard let bot = bots.first(where: { $0.id == botID }), bot.promotedHelper?.handoffID == handoffID, var state = herdrCarryOver(for: bot) else { return }
        let earlier = state.failedFor == failure.launch ? state.failures : 0
        state.failedFor = failure.launch; state.failures = earlier + 1
        setHerdrCarryOver(state, for: bot)
        grokChatLine(HerdrCarryCopy.failed(bot.name, why: failure.why, again: earlier + 1 < HerdrHandoff.attempts), in: bot)
    }
}

/// The lines in a bot's chat about its fresh agent reading the chat so far.
enum HerdrCarryCopy {
    static func read(_ bot: String, summarised: Bool, older: Int, recent: Int, withFiles: Bool) -> String {
        if summarised && recent == 0 {
            return "\(bot) received a summary of the earlier messages in this chat"
        }
        guard withFiles else { return "\(bot) received the last part of this conversation: its server takes no files" }
        let what = summarised && older > 0 ? "a summary of \(older) older messages and the last \(recent)" : (older > 0 ? "the last \(recent) messages, with the older ones to search" : "all \(recent) messages")
        return "\(bot) read the earlier messages in this chat: \(what)"
    }

    static func failed(_ bot: String, why: String, again: Bool) -> String {
        let next = again ? "It is tried once more with your next message." : "It is not tried again for this agent."
        return "\(bot) could not read the earlier messages in this chat. \(why) Your message was sent without it. \(next)"
    }
}
