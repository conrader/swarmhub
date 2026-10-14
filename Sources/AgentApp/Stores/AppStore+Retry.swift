import Foundation

/// P16 Part 3: Retry reads the box first and sends at most once; a cut stream is followed by GET-only passes; P16 Part 5:
/// rounds a quit interrupted are marked, never resumed.
extension AppStore {
    // MARK: Cut-turn schedule

    /// An `incomplete` row gets passes at the schedule's offsets, each GET-only and exempt from the 15 s floor.
    func scheduleCutTurnReconcile(_ row: ChatMessage) {
        guard turns.schedules[row.id] == nil else { return }
        turns.schedules[row.id] = Task { [weak self] in
            await self?.runCutTurnSchedule(row)
            self?.turns.schedules[row.id] = nil
        }
    }

    private func runCutTurnSchedule(_ row: ChatMessage) async {
        let timing = reconcileTiming, clock = ContinuousClock(), start = clock.now
        guard !timing.schedule.isEmpty else { return }
        var slots = timing.schedule[...], retries = timing.unreachable[...]
        var next = start + (slots.first ?? .zero)
        var lastText: (text: String, at: ContinuousClock.Instant)?
        while !Task.isCancelled {
            try? await Task.sleep(until: next, clock: clock)
            guard !Task.isCancelled, row.turnState == .incomplete, let conversation = conversation(containing: row.id) else { return }
            let report = await reconcile(conversation, reason: .schedule)
            guard row.turnState == .incomplete else { return }
            let now = clock.now
            // A pass that could not reach the box (or found the chat busy) uses no slot.
            if report.unreachable || report.skipped || report.read < report.total {
                guard let delay = retries.popFirst() else { return }
                next = now + delay; continue
            }
            retries = timing.unreachable[...]
            // An active run keeps polling without using a slot, up to the cap.
            if report.activeRun, now - start < timing.activeCap { next = now + max(.seconds(1), timing.schedule.dropFirst().first ?? .seconds(3)); continue }
            if let last = lastText, last.text == row.content, now - last.at >= timing.unchangedStop { return }
            if lastText?.text != row.content { lastText = (row.content, now) }
            _ = slots.popFirst()
            guard let offset = slots.first else { return }
            next = start + offset
        }
    }

    // MARK: Retry

    /// A legacy-transport bot has no sessions and gets no one-tap Retry.
    func isLegacyTransport(_ bot: Bot, session: String?) -> Bool {
        session == nil && botFeatures[bot.id].map { !$0.isEmpty && !$0.contains("session_chat_streaming") } == true
    }

    /// The owning bot of a row in a bot chat or thread.
    func owner(of conversation: any Conversation) -> Bot? {
        if let bot = conversation as? Bot { return bot }
        return bots.first { $0.threads.contains { $0 === conversation } }
    }

    /// Offered on a `notSent` reply row: in a bot chat any such row; in a group only a current member's newest row.
    func canRetry(_ row: ChatMessage) -> Bool {
        guard row.role == .assistant, row.turnState == .notSent, let conversation = conversation(containing: row.id) else { return false }
        if let group = conversation as? GroupChat {
            guard let id = row.authorID, group.memberIDs.contains(id), let bot = bots.first(where: { $0.id == id }), !needsKey(bot), (try? backend(for: bot)) != nil,
                  !isLegacyTransport(bot, session: group.session(for: id)) else { return false }
            return group.messages.last { $0.role == .assistant && $0.authorID == id } === row
        }
        guard let bot = owner(of: conversation), !needsKey(bot), (try? backend(for: bot)) != nil else { return false }
        return !isLegacyTransport(bot, session: conversation.hermesSessionID)
    }

    /// The user row a reply row answers.
    func trigger(of row: ChatMessage, in conversation: any Conversation) -> ChatMessage? {
        if let id = row.metadata[TurnKey.forUser].flatMap(UUID.init(uuidString:)), let user = conversation.messages.first(where: { $0.id == id }) { return user }
        guard let index = conversation.messages.firstIndex(where: { $0.id == row.id }) else { return nil }
        return conversation.messages[..<index].last { $0.role == .user && !$0.isSteer && $0.presentation == .text }
    }

    /// Retry on a `notSent` row. Claims the stream slot before its first await, reads the box, adopts what the box has, and
    /// sends into the same row only when the read succeeded, reached back past the row, the box has no such turn and no
    /// newer box turn is unmatched (`sendAnyway` overrides only that last check). An ambiguous row younger than 30 min needs
    /// a second tap.
    func retry(_ row: ChatMessage, sendAnyway: Bool = false) {
        guard canRetry(row), !isStreaming, streamTask == nil, let conversation = conversation(containing: row.id) else { return }
        let group = conversation as? GroupChat
        guard let bot = group.flatMap({ _ in row.authorID.flatMap { id in bots.first { $0.id == id } } }) ?? owner(of: conversation),
              let trigger = trigger(of: row, in: conversation) else { return }
        if row.metadata[TurnKey.ambiguous] == "1", now().timeIntervalSince(row.createdAt) < 1_800, row.metadata[TurnKey.retry] != "confirm", !sendAnyway {
            row.metadata[TurnKey.retry] = "confirm"; return
        }
        let ledger = "\(ObjectIdentifier(conversation).hashValue)|\(bot.id)|\(trigger.id)"
        guard turns.retryLedger.insert(ledger).inserted else { return }
        let token = UUID(); activeStreamToken = token; isStreaming = true
        streamingConversation = conversation; streamingBotID = bot.id; streamingAssistant = row
        let run = group.map { GroupRun(groupID: $0.id) }; if let run { groupRun = run }
        row.metadata[TurnKey.check] = "checking"; row.metadata[TurnKey.retry] = nil
        let content = row.content
        objectWillChange.send()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await performRetry(row, content: content, bot: bot, trigger: trigger, conversation: conversation, group: group, run: run, token: token, sendAnyway: sendAnyway)
            turns.retryLedger.remove(ledger)
            if let run, groupRun === run { groupRun = nil }
            releaseSlot(token)
            objectWillChange.send(); save()
        }
    }

    private func performRetry(_ row: ChatMessage, content: String, bot: Bot, trigger: ChatMessage, conversation: any Conversation, group: GroupChat?, run: GroupRun?, token: UUID, sendAnyway: Bool) async {
        let report = await reconcile(conversation, reason: .retry, ignoringStream: true, member: group == nil ? nil : bot.id)
        if row.metadata[TurnKey.check] == "checking" { row.metadata[TurnKey.check] = nil }
        guard !Task.isCancelled, activeStreamToken == token, !(run?.stopped ?? false) else { return }
        // The box had the turn (adopted, or still running): nothing is sent.
        guard row.turnState == .notSent, row.content == content else { return }
        let covers = report.coversFrom.map { $0 <= row.createdAt.addingTimeInterval(report.skew) } ?? true
        guard report.read == report.total, !report.unreachable, covers else {
            addWarning("\(bot.name): Can't reach the box; nothing was sent.", in: conversation, after: row); return
        }
        if report.newerUnmatched && !sendAnyway {
            row.metadata[TurnKey.retry] = "blocked"
            addWarning("\(bot.name): Can't match the box's newest message; nothing was sent.", in: conversation, after: row); return
        }
        let images: [String]
        do { images = try trigger.attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) }
        catch { addWarning("\(bot.name): \(error.localizedDescription) Nothing was sent.", in: conversation, after: row); return }
        guard let activeBackend = try? backend(for: bot) else { return }
        if let group, let run {
            group.activeMemberID = bot.id
            await groupTurn(bot: bot, group: group, run: run, token: token, images: images, trigger: trigger, reusing: row)
            return
        }
        row.turnState = .incomplete; row.isStreaming = true
        [TurnKey.why, TurnKey.ambiguous, TurnKey.retry, TurnKey.end].forEach { row.metadata[$0] = nil }
        let history = chatHistory(conversation, upTo: trigger, excluding: row)
        let prompt = managementPrompt(for: bot, text: trigger.content, conversation: conversation)
        await runChatTurn(bot: bot, conversation: conversation, assistant: row, history: history, images: images, systemPrompt: prompt, backend: activeBackend, token: token)
    }

    func releaseSlot(_ token: UUID) {
        guard activeStreamToken == token else { return }
        isStreaming = false; streamTask = nil; activeStreamToken = nil; streamingBotID = nil; streamingAssistant = nil; streamingConversation = nil; steerAvailable = false
    }

    // MARK: Launch recovery

    /// Groups whose round was on disk at launch: the active member's row goes to the reconcile; everyone not asked gets
    /// a `notSent` row (why `quit`) and one line. Nothing is sent. A no-op while a turn runs.
    func recoverInterruptedRounds() {
        guard !isStreaming, streamTask == nil, groupRun == nil else { return }
        for group in groups where turns.roundsAtLaunch.contains(group.id) {
            guard let round = group.round else { continue }
            var remaining = round.remaining
            if let active = round.active, !group.messages.contains(where: { $0.authorID == active && $0.metadata[TurnKey.forUser] == round.userMessageID.uuidString }) {
                remaining.insert(active, at: 0)
            }
            let trigger = group.messages.first { $0.id == round.userMessageID } ?? group.messages.last { $0.role == .user }
            if let trigger { markSkipped(remaining, in: group, trigger: trigger, why: "quit") }
            group.round = nil
        }
        turns.roundsAtLaunch = []
        save()
    }
}
