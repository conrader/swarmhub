import Foundation

/// Retry sends a reply that was not sent once more, into the same row; rounds a quit interrupted are marked, never resumed.
extension AppStore {
    // MARK: Retry

    /// Offered on a `notSent` reply row: in a bot chat any such row; in a group only a current member's newest row.
    func canRetry(_ row: ChatMessage) -> Bool {
        guard row.role == .assistant, row.turnState == .notSent, let conversation = conversation(containing: row.id) else { return false }
        if let group = conversation as? GroupChat {
            guard let id = row.authorID, group.memberIDs.contains(id), let bot = bots.first(where: { $0.id == id }), (try? backend(for: bot)) != nil else { return false }
            return group.messages.last { $0.role == .assistant && $0.authorID == id } === row
        }
        guard let bot = conversation as? Bot else { return false }
        return (try? backend(for: bot)) != nil
    }

    /// The user row a reply row answers.
    func trigger(of row: ChatMessage, in conversation: any Conversation) -> ChatMessage? {
        if let id = row.metadata[TurnKey.forUser].flatMap(UUID.init(uuidString:)), let user = conversation.messages.first(where: { $0.id == id }) { return user }
        guard let index = conversation.messages.firstIndex(where: { $0.id == row.id }) else { return nil }
        return conversation.messages[..<index].last { $0.role == .user && !$0.isSteer && $0.presentation == .text }
    }

    /// Retry on a `notSent` row: claims the chat's slot and sends the message it answers again, into the same row. A row
    /// whose message may have reached the server after all (`ambiguous`) and is younger than 30 min needs a second tap.
    func retry(_ row: ChatMessage, sendAnyway: Bool = false) {
        guard canRetry(row), let conversation = conversation(containing: row.id), isIdle(conversation) else { return }
        let group = conversation as? GroupChat
        guard let bot = group.flatMap({ _ in row.authorID.flatMap { id in bots.first { $0.id == id } } }) ?? (conversation as? Bot),
              let trigger = trigger(of: row, in: conversation) else { return }
        if row.metadata[TurnKey.ambiguous] == "1", now().timeIntervalSince(row.createdAt) < 1_800, row.metadata[TurnKey.retry] != "confirm", !sendAnyway {
            row.metadata[TurnKey.retry] = "confirm"; return
        }
        if let full = turnCapacityProblem(for: [bot]) { errorMessage = full; return }
        let ledger = "\(ObjectIdentifier(conversation).hashValue)|\(bot.id)|\(trigger.id)"
        guard turns.retryLedger.insert(ledger).inserted else { return }
        let run = group.map { GroupRun(groupID: $0.id) }
        let turn = beginTurn(in: conversation, bot: bot, assistant: row, groupRun: run), token = turn.token
        row.metadata[TurnKey.retry] = nil
        objectWillChange.send()
        turn.task = Task { [weak self] in
            guard let self else { return }
            await performRetry(row, bot: bot, trigger: trigger, conversation: conversation, group: group, run: run, token: token)
            turns.retryLedger.remove(ledger)
            releaseSlot(token)
            objectWillChange.send(); save()
        }
    }

    private func performRetry(_ row: ChatMessage, bot: Bot, trigger: ChatMessage, conversation: any Conversation, group: GroupChat?, run: GroupRun?, token: UUID) async {
        guard !Task.isCancelled, isCurrent(token), !(run?.stopped ?? false), row.turnState == .notSent else { return }
        let images: [String]
        do { try validateArtifactAccess(trigger, botID: bot.id); images = try trigger.attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) }
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
        await runChatTurn(bot: bot, conversation: conversation, assistant: row, history: history, images: images, systemPrompt: bot.outboundPersona,
                          backend: activeBackend, token: token)
    }

    func releaseSlot(_ token: UUID) {
        guard turn(token: token) != nil else { return }
        endTurn(token)
        sendQueuedNextMessage()
    }

    // MARK: Launch recovery

    /// Groups whose round was on disk at launch: everyone not asked gets
    /// a `notSent` row (why `quit`) and one line. Nothing is sent. A group whose own turn already runs is left alone.
    func recoverInterruptedRounds() {
        for group in groups where turns.roundsAtLaunch.contains(group.id) && isIdle(group) {
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
