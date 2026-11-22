import Foundation

/// Handing a bot its imported conversation (`GrokHandoff`, `HerdrHandoff`): the per-bot switch, what the backend is
/// given for a turn, what the Mac remembers of it, and what the Grok history header says. The summary of a long
/// conversation's older part is in `AppStore+GrokSummary.swift`.
/// It applies to every imported bot that runs on a server, also one imported before this was built: its next message
/// finds its agent without the conversation and is preceded by the handoff. A group's archive is not handed over.
extension AppStore {
    // MARK: The switch

    static func grokHandoffKey(_ botID: UUID) -> String { "grokHandoff.\(botID.uuidString.lowercased())" }
    static func grokHandoffRecordKey(_ botID: UUID) -> String { "grokHandoffDone.\(botID.uuidString.lowercased())" }

    /// On unless the person turned it off for this bot.
    func grokHandsOver(_ bot: Bot) -> Bool { defaults.object(forKey: Self.grokHandoffKey(bot.id)) as? Bool ?? true }

    /// Off also stops a summary that is being made for the bot. On is the person asking for it: an earlier failure
    /// no longer keeps the next message from trying.
    func setGrokHandsOver(_ on: Bool, for bot: Bot) {
        defaults.set(on, forKey: Self.grokHandoffKey(bot.id))
        if on { retryGrokHandoff(for: bot) } else { grokHandoffs.summaries[bot.id]?.cancel() }
        objectWillChange.send()
    }

    /// The bot has an imported conversation and an agent to give it to.
    func grokHandoffApplies(to bot: Bot) -> Bool {
        bot.backend == .herdr && !bot.isReadOnlyArchive && !bot.isDemo && bot.grokSourceID != nil && bot.grokHistoryCount > 0
    }

    /// The bot's next agent is handed its Grok history (so "New conversation" does not start it with nothing).
    func grokHandoffIsOn(for bot: Bot) -> Bool { grokHandoffApplies(to: bot) && grokHandsOver(bot) }

    // MARK: What the Mac remembers

    /// The bot's `GrokHandoffState`, read from its file once and then kept.
    func grokHandoffState(for botID: UUID) -> GrokHandoffState {
        if let known = grokHandoffs.states[botID] { return known }
        let state = GrokHandoffState.load(grokHistory.handoffStateURL(for: botID))
        grokHandoffs.states[botID] = state
        return state
    }

    /// Kept, and written beside the archive. Nothing is written for a bot whose archive is gone.
    func setGrokHandoffState(_ state: GrokHandoffState, for botID: UUID) {
        guard state != grokHandoffState(for: botID) else { return }
        grokHandoffs.states[botID] = state
        if FileManager.default.fileExists(atPath: grokHistory.fileURL(for: botID).path) {
            try? state.save(to: grokHistory.handoffStateURL(for: botID), directory: grokHistory.directory)
        }
        objectWillChange.send()
    }

    func grokHandoffRecord(for bot: Bot) -> GrokHandoffRecord? {
        defaults.data(forKey: Self.grokHandoffRecordKey(bot.id)).flatMap { try? JSONDecoder().decode(GrokHandoffRecord.self, from: $0) }
    }

    /// The bot is gone: its summary is no longer made, and nothing of its handoff is kept.
    func forgetGrokHandoff(_ botID: UUID) {
        grokHandoffs.summaries[botID]?.cancel()
        grokHandoffs.summaries[botID] = nil; grokHandoffs.summarising[botID] = nil; grokHandoffs.states[botID] = nil
        defaults.removeObject(forKey: Self.grokHandoffKey(botID)); defaults.removeObject(forKey: Self.grokHandoffRecordKey(botID))
    }

    // MARK: A turn

    /// What the bot's backend hands over before a message (`HerdrBackend.handoff`); nil leaves the turn as it always was.
    func grokHandoffSource(for bot: Bot) -> HerdrHandoffSource? {
        guard grokHandoffIsOn(for: bot) else { return nil }
        let id = bot.id, state = grokHandoffState(for: id)
        var source = HerdrHandoffSource(lead: GrokHandoff.lead(for: id), prepare: { [weak self] status in await self?.grokHandoff(for: id, status: status) })
        source.read = state.read
        source.failedFor = state.failures?.launch
        source.failures = state.failures?.count ?? 0
        source.delivered = { [weak self] receipt in Task { @MainActor in self?.grokHandedOver(receipt, botID: id) } }
        source.failed = { [weak self] failure in Task { @MainActor in self?.grokHandoffFailed(failure, botID: id) } }
        return source
    }

    /// The handoff as it goes out now: the archive read and laid out off the main actor. When the older part has no
    /// summary yet and one may be made unasked (`grokSummaryAllowed`), it is made, or the one being made is waited
    /// for, at most `turnWait`. Without a new one the handoff goes with the summary there is, however old, or with the
    /// recent part and the full transcript alone.
    func grokHandoff(for botID: UUID, status: @escaping @Sendable (HerdrTurnStatus) -> Void) async -> HerdrHandoff? {
        guard let bot = bots.first(where: { $0.id == botID }), grokHandoffIsOn(for: bot) else { return nil }
        let name = bot.name
        guard let draft = await grokHandoffDraft(for: bot) else { return nil }
        var summary: GrokHandoffCache? = draft.cache
        if draft.plan.needsSummary, grokSummaryAllowed(draft, botID: botID) {
            status(.summarising)
            if let making = grokSummary(for: bot, draft: draft, limit: grokHandoffs.summaryLimit),
               let made = await Self.waited(making, upTo: grokHandoffs.turnWait) {
                summary = made
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

    /// An agent has replied to the handoff. Its launch is remembered, so that nothing is sent to it again however
    /// long the session gets, and an earlier failure is forgotten. When this turn sent it, what went is kept for the
    /// header's line, and the first time the chat says so.
    func grokHandedOver(_ receipt: HerdrHandoffReceipt, botID: UUID) {
        guard let bot = bots.first(where: { $0.id == botID }) else { return }
        var state = grokHandoffState(for: botID)
        if let sent = receipt.handoff { state.readMarker = sent.marker } else if state.read != receipt.launch { state.readMarker = nil }
        state.read = receipt.launch; state.failures = nil
        setGrokHandoffState(state, for: botID)
        guard let handoff = receipt.handoff else { return }
        let first = grokHandoffRecord(for: bot) == nil
        let record = GrokHandoffRecord(marker: handoff.marker, summarised: handoff.summary != nil, older: handoff.olderMessages,
                                       recent: handoff.recentMessages, at: now(), partial: !receipt.withFiles, lines: bot.grokHistoryCount)
        defaults.set(try? JSONEncoder().encode(record), forKey: Self.grokHandoffRecordKey(botID))
        if first { grokChatLine(receipt.withFiles ? GrokHandoffCopy.read(bot.name) : GrokHandoffCopy.readExcerpt(bot.name), in: bot) }
        objectWillChange.send()
    }

    /// The handoff failed and the person's message went without it: counted for that launch of the agent, and said
    /// in the chat with why and where to try again or switch it off. At `HerdrHandoff.attempts` for one launch the
    /// backend no longer tries by itself (`HerdrHandoffSource.failures`).
    func grokHandoffFailed(_ failure: HerdrHandoffFailure, botID: UUID) {
        guard let bot = bots.first(where: { $0.id == botID }) else { return }
        var state = grokHandoffState(for: botID)
        let earlier = state.failures?.launch == failure.launch ? (state.failures?.count ?? 0) : 0
        state.failures = GrokHandoffState.Failures(launch: failure.launch, count: earlier + 1, why: failure.why, at: now())
        setGrokHandoffState(state, for: botID)
        grokChatLine(GrokHandoffCopy.failed(bot.name, why: failure.why, again: earlier + 1 < HerdrHandoff.attempts), in: bot)
    }

    /// The person asked for the handoff again (the header's "Try again", or the switch turned on): the next message
    /// tries, whatever failed before.
    func retryGrokHandoff(for bot: Bot) {
        var state = grokHandoffState(for: bot.id)
        guard state.failures != nil else { return }
        state.failures = nil
        setGrokHandoffState(state, for: bot.id)
    }

    /// One app-only line in the bot's chat, above the message of the turn that is running (the agent read, or did
    /// not read, the conversation before that message); at the end when no turn runs.
    func grokChatLine(_ text: String, in bot: Bot) {
        let line = AppOnlyLine.line(text)
        if let reply = turn(in: bot)?.assistant, let index = bot.messages.firstIndex(where: { $0 === reply }) {
            bot.messages.insert(line, at: index > 0 && bot.messages[index - 1].role == .user ? index - 1 : index)
        } else {
            bot.messages.append(line)
        }
        objectWillChange.send(); save()
    }

    /// What the bot's running turn takes as a steer follows what its backend offers now. A turn that is handing the
    /// conversation over offers nothing (`HerdrBackend.features`), so a message sent meanwhile waits as the chat's
    /// next message and goes after the first one, in order; once the handoff has ended the turn takes steers again.
    /// Only for a bot that is handed a conversation, so every other bot's turn is left exactly as it was; never for
    /// a turn the person stopped; and asked only when the answer could change something: at a hidden step while
    /// steers are on, at any other status while they are off.
    func steerFollowsBackend(of bot: Bot, at status: HerdrTurnStatus?) async {
        guard grokHandoffIsOn(for: bot), let running = turn(in: bot), !running.stopping, let active = running.backend, let status else { return }
        let hidden = status == .summarising || status == .readingHistory
        guard running.steerAvailable == hidden else { return }
        let token = running.token
        let flags = try? await active.features()
        // The person may have pressed Stop meanwhile: a stopping turn takes no steer.
        guard let still = turn(token: token), !still.stopping else { return }
        setSteerAvailable(flags?.contains("run_steer") == true, token: token)
    }

    // MARK: What the header says

    /// The line under the bot's Grok history: off, not handed over and why, being prepared, when it was last handed
    /// over, or that it will be.
    func grokHandoffLine(for bot: Bot) -> String {
        guard grokHandsOver(bot) else { return GrokHandoffCopy.off(bot.name) }
        let state = grokHandoffState(for: bot.id)
        if let failures = state.failures {
            return GrokHandoffCopy.notHandedOver(bot.name, why: failures.why, again: failures.count < HerdrHandoff.attempts)
        }
        if let older = grokHandoffs.summarising[bot.id] { return GrokHandoffCopy.preparing(older) }
        let saved = grokHandoffRecord(for: bot)
        var notes: [String] = []
        if let hold = state.summaryHold, saved?.summarised != true { notes.append(hold.tooLong ? GrokHandoffCopy.tooLong : GrokHandoffCopy.noSummary) }
        guard let record = saved else { return ([GrokHandoffCopy.pending(bot.name)] + notes).joined(separator: " · ") }
        if let lines = record.lines, lines != bot.grokHistoryCount { notes.append(GrokHandoffCopy.newer) }
        return GrokHandoffCopy.handedOver(bot.name, record: record, when: record.at.formatted(date: .abbreviated, time: .shortened), notes: notes)
    }

    /// The header offers "Try again" while the last handoff failed, and "Try summary again" while the summary is
    /// not being made by itself.
    func grokOffersRetry(for bot: Bot) -> Bool { grokHandsOver(bot) && grokHandoffState(for: bot.id).failures != nil }
    func grokOffersSummary(for bot: Bot) -> Bool {
        grokHandsOver(bot) && grokHandoffState(for: bot.id).summaryHold != nil && grokHandoffs.summaries[bot.id] == nil
    }
}
