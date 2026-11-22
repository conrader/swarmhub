import Foundation

/// The summary of the older part of a long imported conversation (`GrokHandoff.summarise`): when the app makes one by
/// itself, when it leaves that be, and the person's own request for one.
/// By itself it is made after an import and before a bot's first message, once per revision of the archive: an
/// older part of more than `GrokHandoff.unaskedParts` files is never summarised unasked, and after a summary failed
/// or ran out of time none is started again for a day (`GrokHandoffState.summaryHold`). Meanwhile the handoff goes at
/// once with the recent part and the full transcript. New lines in the archive lift the hold, and so does
/// "Try summary again" under the bot's Grok history.
extension AppStore {
    /// Whether the summary this draft needs may be made now without being asked for. Notes an older part that is
    /// too long for that.
    func grokSummaryAllowed(_ draft: GrokHandoff.Draft, botID: UUID) -> Bool {
        var state = grokHandoffState(for: botID)
        let revision = draft.transcript.revision
        if state.holdsSummary(of: revision, now: now()) { return false }
        // One that is being made (the person asked for it) is waited for whatever its size.
        if draft.parts > GrokHandoff.unaskedParts, grokHandoffs.summaries[botID] == nil {
            state.summaryHold = GrokHandoffState.SummaryHold(revision: revision, at: now(), tooLong: true)
            setGrokHandoffState(state, for: botID)
            return false
        }
        return true
    }

    /// Starts making the summary of the bot's older part, or returns the one being made. It runs after the summary
    /// started before it on the same server, and at most `limit`. nil when the bot's server cannot be reached at all
    /// (no address or key).
    @discardableResult func grokSummary(for bot: Bot, draft: GrokHandoff.Draft, limit: Duration) -> Task<GrokHandoffCache?, Never>? {
        if let making = grokHandoffs.summaries[bot.id] { return making }
        let server = herdrServer(for: bot)
        guard let client = try? herdrClient(for: server) else { return nil }
        let id = bot.id, name = bot.name, template = herdrTemplate(for: bot), model = herdrModel(for: bot)
        let archive = grokHistory.fileURL(for: id), cache = grokHistory.handoffURL(for: id), directory = grokHistory.directory
        let started = now(), revision = draft.transcript.revision
        let earlier = grokHandoffs.queue[server.id]
        let task = Task<GrokHandoffCache?, Never> { [weak self] in
            _ = await earlier?.value
            let made = await GrokHandoff.summarise(draft, botName: name, archiveID: id, client: client, template: template, model: model,
                                                   limit: limit, archive: archive, cache: cache, directory: directory, now: started)
            self?.grokSummaryEnded(id, made: made != nil, revision: revision, stopped: Task.isCancelled)
            return made
        }
        grokHandoffs.summaries[id] = task
        grokHandoffs.summarising[id] = draft.plan.older.count
        grokHandoffs.queue[server.id] = Task { _ = await task.value }
        objectWillChange.send()
        return task
    }

    /// A summary that could not be made holds the next one back for a day; one that was made lifts any hold. One
    /// that was stopped (the bot was removed, or its switch turned off) leaves nothing behind.
    private func grokSummaryEnded(_ botID: UUID, made: Bool, revision: String, stopped: Bool) {
        grokHandoffs.summaries[botID] = nil; grokHandoffs.summarising[botID] = nil
        if !stopped {
            var state = grokHandoffState(for: botID)
            state.summaryHold = made ? nil : GrokHandoffState.SummaryHold(revision: revision, at: now(), tooLong: false)
            setGrokHandoffState(state, for: botID)
        }
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
    /// background. Only in a real window (`launchWorkEnabled`), and only for a bot whose handoff is on.
    func grokImported(_ ids: [UUID]) {
        guard launchWorkEnabled else { return }
        for id in ids { Task { [weak self] in _ = await self?.prepareGrokSummary(for: id) } }
    }

    /// Starts the bot's summary when its conversation needs one that is not there yet; returns the work, when any.
    /// Never for a bot whose handoff is off. `asked`: the person asked for it, so no hold applies, the older part
    /// may be as long as a summary takes at all, and it may take longer.
    @discardableResult func prepareGrokSummary(for botID: UUID, asked: Bool = false) async -> Task<GrokHandoffCache?, Never>? {
        guard let bot = bots.first(where: { $0.id == botID }), grokHandoffIsOn(for: bot),
              let draft = await grokHandoffDraft(for: bot), draft.plan.needsSummary else { return nil }
        if !asked, !grokSummaryAllowed(draft, botID: botID) { return nil }
        return grokSummary(for: bot, draft: draft, limit: asked ? grokHandoffs.askedLimit : grokHandoffs.summaryLimit)
    }

    /// "Try summary again": the hold is lifted and the summary is made now. The bot's next agent is handed it; the
    /// one that is running already has the conversation as it went.
    @discardableResult func retryGrokSummary(for bot: Bot) async -> Task<GrokHandoffCache?, Never>? {
        var state = grokHandoffState(for: bot.id)
        state.summaryHold = nil
        setGrokHandoffState(state, for: bot.id)
        return await prepareGrokSummary(for: bot.id, asked: true)
    }
}
