import Foundation

/// What the app remembers of a bot's last handoff, for the line on its Grok history (`UserDefaults`). Whether an agent
/// session has had the handoff is never read from here: the server's saved rows say that (`HerdrClient.handoffState`).
struct GrokHandoffRecord: Codable, Equatable, Sendable {
    var marker: String
    var summarised: Bool
    var older: Int, recent: Int
    var at: Date
}

/// The handoffs' bookkeeping that lives beside the store (memory only).
@MainActor final class GrokHandoffBook {
    /// The summaries being made right now, by bot, and how many older messages each stands for.
    var summaries: [UUID: Task<GrokHandoffCache?, Never>] = [:]
    var summarising: [UUID: Int] = [:]
    /// The newest summary started on each server: the next one there waits for it, so one runs at a time per server.
    var queue: [String: Task<Void, Never>] = [:]
    /// The bots whose last summary could not be made.
    var failed: Set<UUID> = []
    /// How long a turn waits for a summary before the handoff goes without one, and how long making one may take.
    var turnWait: Duration = .seconds(180)
    var summaryLimit: Duration = .seconds(900)
}

/// The words of the handoff line under a bot's Grok history.
enum GrokHandoffCopy {
    static func switchLabel(_ bot: String) -> String { "Hand this history over to \(bot)" }
    static func switchHelp(_ bot: String) -> String {
        "On: \(bot) reads this conversation before its next reply whenever its agent starts anew, so it can carry on. It is sent to \(bot)’s server. Off: \(bot) does not get it."
    }
    static func off(_ bot: String) -> String { "Not handed over to \(bot)" }
    static func pending(_ bot: String) -> String { "\(bot) reads this before its next reply" }
    static func preparing(_ older: Int) -> String { "Preparing handover: summarising \(older) older messages…" }
    static func read(_ bot: String) -> String { "\(bot) has read its Grok history" }

    /// "Handed over to Ada · summary of 268 + last 120 messages · 3 May 2026 at 14:02".
    static func handedOver(_ bot: String, record: GrokHandoffRecord, when: String) -> String {
        let what: String
        if record.older == 0 { what = "all \(record.recent) messages" }
        else if record.summarised { what = "summary of \(record.older) + last \(record.recent) messages" }
        else { what = "last \(record.recent) messages and the full transcript, without a summary" }
        return "Handed over to \(bot) · \(what) · \(when)"
    }
}

/// Handing a bot its imported conversation (`GrokHandoff`, `HerdrHandoff`): the per-bot switch, what the backend is
/// given for a turn, the summary of a long conversation's older part, and what the Grok history header says.
/// It applies to every imported bot that runs on a server, also one imported before this was built: its next message
/// finds no marker in its agent session and is preceded by the handoff. A group's archive is not handed over.
extension AppStore {
    // MARK: The switch

    static func grokHandoffKey(_ botID: UUID) -> String { "grokHandoff.\(botID.uuidString.lowercased())" }
    static func grokHandoffRecordKey(_ botID: UUID) -> String { "grokHandoffDone.\(botID.uuidString.lowercased())" }

    /// On unless the person turned it off for this bot.
    func grokHandsOver(_ bot: Bot) -> Bool { defaults.object(forKey: Self.grokHandoffKey(bot.id)) as? Bool ?? true }
    func setGrokHandsOver(_ on: Bool, for bot: Bot) { defaults.set(on, forKey: Self.grokHandoffKey(bot.id)); objectWillChange.send() }

    /// The bot has an imported conversation and an agent to give it to.
    func grokHandoffApplies(to bot: Bot) -> Bool {
        bot.backend == .herdr && !bot.isReadOnlyArchive && !bot.isDemo && bot.grokSourceID != nil && bot.grokHistoryCount > 0
    }

    // MARK: A turn

    /// What the bot's backend hands over before a message (`HerdrBackend.handoff`); nil leaves the turn as it always was.
    func grokHandoffSource(for bot: Bot) -> HerdrHandoffSource? {
        guard grokHandoffApplies(to: bot), grokHandsOver(bot) else { return nil }
        let id = bot.id
        return HerdrHandoffSource(
            lead: GrokHandoff.lead(for: id),
            prepare: { [weak self] status in await self?.grokHandoff(for: id, status: status) },
            delivered: { [weak self] handoff in Task { @MainActor in self?.grokHandedOver(handoff, botID: id) } })
    }

    /// The handoff as it goes out now: the archive read and laid out off the main actor. When the older part has no
    /// summary yet, one is made (or the one being made is waited for), at most `turnWait`; without it the handoff
    /// goes with the recent part and the full transcript alone.
    func grokHandoff(for botID: UUID, status: @escaping @Sendable (HerdrTurnStatus) -> Void) async -> HerdrHandoff? {
        guard let bot = bots.first(where: { $0.id == botID }), grokHandoffApplies(to: bot), grokHandsOver(bot) else { return nil }
        let name = bot.name
        guard let draft = await grokHandoffDraft(for: bot) else { return nil }
        var summary: String? = draft.cache?.summary
        if draft.plan.needsSummary {
            status(.summarising)
            if let making = grokSummary(for: bot, draft: draft) {
                summary = await Self.waited(making, upTo: grokHandoffs.turnWait)?.summary
            }
        }
        let used = summary
        let rendered = await Task.detached(priority: .userInitiated) {
            GrokHandoff.render(draft.transcript, plan: draft.plan, summary: used, botName: name)
        }.value
        return GrokHandoff.package(rendered, archiveID: botID)
    }

    func grokHandoffDraft(for bot: Bot) async -> GrokHandoff.Draft? {
        let archive = grokHistory.fileURL(for: bot.id), cache = grokHistory.handoffURL(for: bot.id), name = bot.name
        return await Task.detached(priority: .userInitiated) {
            GrokHandoff.draft(archive: archive, cache: cache, botName: name)
        }.value
    }

    /// An agent has read the handoff: kept for the header's line, and said once in the chat, above the message the
    /// agent read it before.
    func grokHandedOver(_ handoff: HerdrHandoff, botID: UUID) {
        guard let bot = bots.first(where: { $0.id == botID }) else { return }
        let first = grokHandoffRecord(for: bot) == nil
        let record = GrokHandoffRecord(marker: handoff.marker, summarised: handoff.summary != nil, older: handoff.olderMessages,
                                       recent: handoff.recentMessages, at: now())
        defaults.set(try? JSONEncoder().encode(record), forKey: Self.grokHandoffRecordKey(botID))
        if first {
            let line = AppOnlyLine.line(GrokHandoffCopy.read(bot.name))
            if let reply = turn(in: bot)?.assistant, let index = bot.messages.firstIndex(where: { $0 === reply }) {
                bot.messages.insert(line, at: index > 0 && bot.messages[index - 1].role == .user ? index - 1 : index)
            } else {
                bot.messages.append(line)
            }
            save()
        }
        objectWillChange.send()
    }

    func grokHandoffRecord(for bot: Bot) -> GrokHandoffRecord? {
        defaults.data(forKey: Self.grokHandoffRecordKey(bot.id)).flatMap { try? JSONDecoder().decode(GrokHandoffRecord.self, from: $0) }
    }

    /// The bot is gone: its summary is no longer made, and nothing of its handoff is kept.
    func forgetGrokHandoff(_ botID: UUID) {
        grokHandoffs.summaries[botID]?.cancel()
        grokHandoffs.summaries[botID] = nil; grokHandoffs.summarising[botID] = nil; grokHandoffs.failed.remove(botID)
        defaults.removeObject(forKey: Self.grokHandoffKey(botID)); defaults.removeObject(forKey: Self.grokHandoffRecordKey(botID))
    }

    // MARK: The summary

    /// Starts making the summary of the bot's older part, or returns the one being made. It runs after the summary
    /// started before it on the same server. nil when the bot's server cannot be reached at all (no address or key).
    @discardableResult func grokSummary(for bot: Bot, draft: GrokHandoff.Draft) -> Task<GrokHandoffCache?, Never>? {
        if let making = grokHandoffs.summaries[bot.id] { return making }
        let server = herdrServer(for: bot)
        guard let client = try? herdrClient(for: server) else { return nil }
        let id = bot.id, name = bot.name, template = herdrTemplate(for: bot), model = herdrModel(for: bot)
        let archive = grokHistory.fileURL(for: id), cache = grokHistory.handoffURL(for: id), directory = grokHistory.directory
        let limit = grokHandoffs.summaryLimit, started = now()
        let earlier = grokHandoffs.queue[server.id]
        let task = Task<GrokHandoffCache?, Never> { [weak self] in
            _ = await earlier?.value
            let made = await GrokHandoff.summarise(draft, botName: name, archiveID: id, client: client, template: template, model: model,
                                                   limit: limit, archive: archive, cache: cache, directory: directory, now: started)
            self?.grokSummaryEnded(id, made: made != nil)
            return made
        }
        grokHandoffs.summaries[id] = task
        grokHandoffs.summarising[id] = draft.plan.older.count
        grokHandoffs.queue[server.id] = Task { _ = await task.value }
        objectWillChange.send()
        return task
    }

    private func grokSummaryEnded(_ botID: UUID, made: Bool) {
        grokHandoffs.summaries[botID] = nil; grokHandoffs.summarising[botID] = nil
        if made { grokHandoffs.failed.remove(botID) } else { grokHandoffs.failed.insert(botID) }
        objectWillChange.send()
    }

    /// What `task` came to, or nil when it has not ended within `limit`. The task goes on either way: a summary that
    /// comes late is saved for the bot's next agent.
    nonisolated static func waited(_ task: Task<GrokHandoffCache?, Never>, upTo limit: Duration) async -> GrokHandoffCache? {
        enum Heard: Sendable { case ended(GrokHandoffCache?), late }
        let (heard, feed) = AsyncStream<Heard>.makeStream()
        let waiter = Task {
            let made = await task.value
            feed.yield(.ended(made)); feed.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            feed.yield(.late); feed.finish()
        }
        defer { waiter.cancel(); timer.cancel() }
        for await first in heard {
            if case .ended(let made) = first { return made }
            return nil
        }
        return nil
    }

    /// After an import: the summary of each imported bot's older part is made ahead of its first message, in the
    /// background. Only in a real window (`launchWorkEnabled`); a bot whose conversation fits, or whose summary is
    /// there, needs none.
    func grokImported(_ ids: [UUID]) {
        guard launchWorkEnabled else { return }
        for id in ids { Task { [weak self] in _ = await self?.prepareGrokSummary(for: id) } }
    }

    /// Starts the bot's summary when its conversation needs one that is not there yet; returns the work, when any.
    @discardableResult func prepareGrokSummary(for botID: UUID) async -> Task<GrokHandoffCache?, Never>? {
        guard let bot = bots.first(where: { $0.id == botID }), grokHandoffApplies(to: bot), grokHandsOver(bot),
              let draft = await grokHandoffDraft(for: bot), draft.plan.needsSummary else { return nil }
        return grokSummary(for: bot, draft: draft)
    }

    // MARK: What the header says

    /// The line under the bot's Grok history: off, being prepared, when it was last handed over, or that it will be.
    func grokHandoffLine(for bot: Bot) -> String {
        guard grokHandsOver(bot) else { return GrokHandoffCopy.off(bot.name) }
        if let older = grokHandoffs.summarising[bot.id] { return GrokHandoffCopy.preparing(older) }
        guard let record = grokHandoffRecord(for: bot) else { return GrokHandoffCopy.pending(bot.name) }
        return GrokHandoffCopy.handedOver(bot.name, record: record, when: record.at.formatted(date: .abbreviated, time: .shortened))
    }
}
