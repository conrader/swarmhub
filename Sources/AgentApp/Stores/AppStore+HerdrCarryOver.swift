import Foundation

/// A bot whose agent program or model was changed carries on: the agent program keeps a conversation itself, so
/// an agent that starts fresh on the new choice knows nothing of what was said. When a change is applied
/// (`AppStore+HerdrModels.swift`) the Mac notes for each changed bot which agent was running then. That agent has
/// the conversation and is never handed it; the next agent the bot starts is another launch, and before the
/// person's message it reads the bot's chat so far, once: the recent part word for word, a summary of the older
/// part when the chat is long, and the whole of it as a file to search. It travels the way an imported
/// conversation does (`HerdrHandoff`, `HerdrBackend.handOver`), so it never holds a message back.
/// A bot that is handed an imported conversation keeps that handoff instead.
extension AppStore {
    /// What the Mac remembers while a bot's next agent is to read its chat.
    struct HerdrCarryOver: Codable, Equatable {
        /// The agent that was running when the change was made; nil when the bot had none.
        var old: HerdrAgentLaunch?
        /// The launch the handoff last failed for, and how often in a row (`HerdrHandoffSource.failures`).
        var failedFor: HerdrAgentLaunch? = nil
        var failures = 0
        var at: Date
    }

    static func herdrCarryOverKey(_ botID: UUID) -> String { "herdrCarryOver.\(botID.uuidString.lowercased())" }

    func herdrCarryOver(for bot: Bot) -> HerdrCarryOver? {
        defaults.data(forKey: Self.herdrCarryOverKey(bot.id)).flatMap { try? JSONDecoder().decode(HerdrCarryOver.self, from: $0) }
    }

    func setHerdrCarryOver(_ state: HerdrCarryOver?, for bot: Bot) {
        if let state { defaults.set(try? JSONEncoder().encode(state), forKey: Self.herdrCarryOverKey(bot.id)) }
        else { defaults.removeObject(forKey: Self.herdrCarryOverKey(bot.id)); grokHandoffs.carrySummaries[bot.id] = nil }
    }

    /// The bot is gone: nothing of this is kept.
    func forgetHerdrCarryOver(_ botID: UUID) {
        defaults.removeObject(forKey: Self.herdrCarryOverKey(botID)); grokHandoffs.carrySummaries[botID] = nil
    }

    /// The bot has a chat a fresh agent would not know, and no imported conversation that is handed over instead.
    func herdrCarryApplies(to bot: Bot) -> Bool {
        bot.backend == .herdr && !bot.isReadOnlyArchive && !bot.isDemo && !grokHandoffIsOn(for: bot) && !herdrCarryLines(of: bot).isEmpty
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
            grokHandoffs.carrySummaries[bot.id] = nil
            setHerdrCarryOver(HerdrCarryOver(old: running[bot.id], at: now()), for: bot)
        }
    }

    // MARK: The chat as a conversation to hand over

    /// What the person and the bot said in the bot's chat, oldest first, numbered from 1. Left out: the app's own
    /// lines, tool rows, a reply that is being written, and the messages the bot has not answered yet (the one being
    /// sent now, and any waiting behind it): those reach the agent by themselves, after the handoff.
    func herdrCarryLines(of bot: Bot) -> [ArchivedMessage] {
        var rows = bot.messages.filter { message in
            (message.role == .user || message.role == .assistant) && !message.isStreaming && message.presentation == .text && !AppOnlyLine.isAppOnly(message)
        }
        while let last = rows.last, last.role == .user { rows.removeLast() }
        var lines: [ArchivedMessage] = []
        for (index, message) in rows.enumerated() {
            let text = message.role == .assistant ? SwarmhubBlock.visibleText(message.content) : message.content
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // A message the app passed on for another bot is not the person's: it reads as "Infra → Legal".
            let passedOn = message.role == .user && isAppWritten(message)
            let sender = passedOn ? (herdrPassedOnRow(message)?.sender?.name ?? AppConstants.name) : nil
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
        var source = HerdrHandoffSource(lead: GrokHandoff.lead(for: id), prepare: { [weak self] status in await self?.herdrCarryHandoff(for: id, status: status) })
        // The agent that ran before the change holds the conversation itself.
        source.read = state.old
        source.failedFor = state.failedFor
        source.failures = state.failures
        source.delivered = { [weak self] receipt in Task { @MainActor in self?.herdrCarriedOver(receipt, botID: id) } }
        source.failed = { [weak self] failure in Task { @MainActor in self?.herdrCarryFailed(failure, botID: id) } }
        return source
    }

    /// The chat as it goes to the fresh agent. A long chat's older part is summarised by a one-off agent of the bot's
    /// own program and model (`HerdrClient.summarise`), for at most as long as a turn waits for a summary; without
    /// one the handoff goes with the recent part and the whole chat to search. An older part that would take the
    /// one-off agent several rounds is not summarised. nil when nothing was said: the message goes as it always did.
    func herdrCarryHandoff(for botID: UUID, status: @escaping @Sendable (HerdrTurnStatus) -> Void) async -> HerdrHandoff? {
        guard let bot = bots.first(where: { $0.id == botID }), herdrCarryOver(for: bot) != nil else { return nil }
        let lines = herdrCarryLines(of: bot), name = bot.name
        guard !lines.isEmpty else { setHerdrCarryOver(nil, for: bot); return nil }
        let transcript = GrokHandoff.Transcript(lines)
        let kept = grokHandoffs.carrySummaries[botID]
        let plan = GrokHandoff.plan(transcript, botName: name, summarisedThrough: kept?.through)
        var summary: GrokHandoffCache? = nil
        if let kept, let oldest = plan.older.first, kept.through >= oldest.seq { summary = kept }
        if plan.needsSummary, let pieces = GrokHandoff.parts(of: plan.older, botName: name), pieces.texts.count <= GrokHandoff.unaskedParts,
           let client = try? herdrClient(for: herdrServer(for: bot)) {
            status(.summarising)
            let template = herdrTemplate(for: bot), model = herdrModel(for: bot)
            if let written = try? await client.summarise(pieces.files, name: HerdrClient.compactorName(for: botID), template: template, model: model, limit: grokHandoffs.turnWait) {
                let made = GrokHandoffCache(summary: written, from: pieces.from, through: pieces.through, messages: pieces.messages,
                                            template: template ?? "", model: model, madeAt: now())
                if !made.summary.isEmpty { summary = made; grokHandoffs.carrySummaries[botID] = made }
            }
        }
        let used = summary
        let rendered = await Task.detached(priority: .userInitiated) {
            GrokHandoff.render(transcript, plan: plan, summary: used, botName: name, origin: .ownChat)
        }.value
        return GrokHandoff.package(rendered, archiveID: botID, origin: .ownChat)
    }

    /// A fresh agent has replied to the handoff: it has the chat, so nothing more is handed over until the bot's
    /// program or model changes again. When this turn sent it, the chat says so.
    func herdrCarriedOver(_ receipt: HerdrHandoffReceipt, botID: UUID) {
        guard let bot = bots.first(where: { $0.id == botID }), herdrCarryOver(for: bot) != nil else { return }
        setHerdrCarryOver(nil, for: bot)
        guard let handoff = receipt.handoff else { return }
        grokChatLine(HerdrCarryCopy.read(bot.name, summarised: handoff.summary != nil, older: handoff.olderMessages, recent: handoff.recentMessages, withFiles: receipt.withFiles), in: bot)
    }

    /// The handoff failed and the person's message went without it: counted for that launch of the agent, and said
    /// in the chat. At `HerdrHandoff.attempts` for one launch the backend no longer tries for it.
    func herdrCarryFailed(_ failure: HerdrHandoffFailure, botID: UUID) {
        guard let bot = bots.first(where: { $0.id == botID }), var state = herdrCarryOver(for: bot) else { return }
        let earlier = state.failedFor == failure.launch ? state.failures : 0
        state.failedFor = failure.launch; state.failures = earlier + 1
        setHerdrCarryOver(state, for: bot)
        grokChatLine(HerdrCarryCopy.failed(bot.name, why: failure.why, again: earlier + 1 < HerdrHandoff.attempts), in: bot)
    }
}

/// The lines in a bot's chat about its fresh agent reading the chat so far.
enum HerdrCarryCopy {
    static func read(_ bot: String, summarised: Bool, older: Int, recent: Int, withFiles: Bool) -> String {
        guard withFiles else { return "\(bot) started fresh and was given the last part of this conversation: its server takes no files" }
        let what = summarised && older > 0 ? "a summary of \(older) older messages and the last \(recent)" : (older > 0 ? "the last \(recent) messages, with the older ones to search" : "all \(recent) messages")
        return "\(bot) started fresh and read this conversation first: \(what)"
    }

    static func failed(_ bot: String, why: String, again: Bool) -> String {
        let next = again ? "It is tried once more with your next message." : "It is not tried again for this agent."
        return "\(bot) started fresh and could not be given this conversation. \(why) Your message was sent without it. \(next)"
    }
}
