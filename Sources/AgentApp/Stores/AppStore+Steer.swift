import Foundation

/// Bubble metadata: `steer` on a queued steer (sent → queued → delivered | failed; failed → next → sentNext after
/// "Send as next message"), `correction` on a message that an older build sent after a steer was handed back.
enum SteerKey { static let steer = "steer", correction = "correction" }

/// The plain words.
enum SteerCopy {
    /// Sent before the correction's text (never shown in the bubble).
    static let lead = "(Correction while you were answering:)"
    static let placeholder = "Add to this answer…"
    static let hint = "Follow-ups go to the current turn. Check the receipt below your message."
    /// Legacy automatic wait caption, used to recover old queues.
    static let afterTurn = "Sends when the current answer ends."
    /// The status line under a failed steer: only the reason (the bubble's caption already says "Not delivered").
    static let endedFirst = "The answer ended first."
    static let sendAsNext = "Send as next message"

    /// The caption over a steer or correction bubble; nil for any other message.
    static func caption(_ message: ChatMessage, botName: String? = nil) -> String? {
        switch message.metadata[SteerKey.correction] {
        case "stopping": return "Stopping the answer…"
        case "stopped": return "Stopped the answer and sent your correction"
        case "followup": return "Sent after the answer finished"
        default: break
        }
        switch message.metadata[SteerKey.steer] {
        case nil: return nil
        case "sent": return "Accepted · sending to current turn…"
        case "queued": return "Accepted · delivery unconfirmed"
        case "uncertain": return "Delivery unconfirmed"
        case "failed": return "Not delivered"
        case "goalContext": return "Saved to goal context"
        case "next": return "Sends as the next message when the answer ends"
        case "sentNext": return "It did not get into that answer, so it was sent as your next message"
        case "delivered": return "Delivered"
        default: return "Delivery unconfirmed"
        }
    }
}

/// Receipts for one specific running reply, including independently steered group members.
struct PendingSteer {
    let conversation: any Conversation
    var bubbles: [ChatMessage] = []
}

extension AppStore {
    // MARK: Entry

    func steer(_ message: ChatMessage, bot: Bot, turn: ConversationTurn) -> Bool {
        guard !bot.isReadOnlyArchive, storeRestoreOffer == nil, turn.botID == bot.id else { return false }
        let conversation = turn.conversation
        let files: [HerdrClient.TaskFile]
        do {
            try validateArtifactAccess(message, botID: bot.id)
            files = try message.attachments.map(attachmentEncoder.taskFile(for:))
            try HerdrClient.TaskFile.validate(files)
        } catch { presentError(error.localizedDescription, reason: .attachment, bot: bot); return false }
        captureAttachments(message, readers: [bot.id])
        insertInActiveTurn(message, in: conversation, after: turn.assistant)
        guard turn.steerAvailable, !turn.stopping, let backend = turn.backend, turn.assistant != nil else {
            message.metadata[SteerKey.steer] = "failed"
            addWarning("The current turn cannot accept this follow-up.", in: conversation, after: message)
            objectWillChange.send(); save()
            return true
        }
        noteFirstSteer()
        message.metadata[SteerKey.steer] = "sent"
        deliverSteer(message.modelText.trimmingCharacters(in: .whitespacesAndNewlines), into: conversation,
                     sessionID: turnSessionID(in: conversation, bot: bot), backend: backend, bubble: message, files: files, slot: turn)
        return true
    }

    func noteFirstSteer() {
        guard !defaults.bool(forKey: "steerHintShown") else { return }
        defaults.set(true, forKey: "steerHintShown"); steerHint = SteerCopy.hint
    }

    /// The first reply row of `conversation`'s running turn (the key of its steers and parts).
    func streamingTurnOrigin(in conversation: any Conversation) -> UUID? {
        return steerOrigin(turn(in: conversation))
    }

    func steerOrigin(_ turn: ConversationTurn?) -> UUID? {
        guard let row = turn?.assistant else { return nil }
        return turns.parts.first { $0.value === row }?.key ?? row.id
    }

    // MARK: Queued

    /// Shows the steer bubble and posts it; it waits for the running step to end. A refusal marks it and says why.
    func deliverSteer(_ value: String, into conversation: any Conversation, sessionID: String, backend activeBackend: any AgentBackend, bubble: ChatMessage? = nil, files: [HerdrClient.TaskFile] = [], slot: ConversationTurn? = nil) {
        let message = bubble ?? ChatMessage(role: .user, content: value, metadata: [SteerKey.steer: "sent"])
        let slot = slot ?? turn(in: conversation)
        if bubble == nil { insertInActiveTurn(message, in: conversation, after: slot?.assistant) }
        let recipient = slot?.botID
        if let origin = steerOrigin(slot) {
            turns.steers[origin, default: PendingSteer(conversation: conversation)].bubbles.append(message)
        }
        let goalID = (conversation as? Bot)?.goal.flatMap { $0.state.active ? $0.id : nil }
        turns.inFlightSteers.insert(message.id)
        objectWillChange.send(); save()
        let delivery = Task {
            defer {
                turns.inFlightSteers.remove(message.id)
                slot?.guidanceReceipts[message.id] = nil
            }
            do {
                guard steerHeldByTurn(message), let slot, isCurrent(slot.token), !slot.stopping, slot.botID == recipient else {
                    throw BackendError.unavailable(SteerCopy.endedFirst)
                }
                guard let recipient, bots.contains(where: { $0.id == recipient && !$0.isReadOnlyArchive }),
                      storeRestoreOffer == nil else { throw BackendError.unavailable("This recipient is unavailable.") }
                if let group = conversation as? GroupChat,
                   !groups.contains(where: { $0 === group }) || !group.memberIDs.contains(recipient) {
                    throw BackendError.unavailable("This recipient left the group.")
                }
                try validateArtifactAccess(message, botID: recipient)
                try await activeBackend.steer(sessionID: sessionID, text: value, files: files)
                message.metadata[SteerKey.steer] = "delivered"
                if let bot = conversation as? Bot, let goalID, bot.goal?.id == goalID, bot.goal?.state.active == true {
                    bot.goal?.objective += "\nFollow-up: " + value + files.map { "\nAttached file: " + $0.name }.joined()
                }
            } catch {
                let uncertain: Bool
                switch error {
                case BackendError.http(let code, _) where code >= 500: uncertain = true
                case let network as URLError:
                    uncertain = ![.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(network.code)
                case is DecodingError, HerdrClient.Failure.unconfirmedDelivery: uncertain = true
                default: uncertain = false
                }
                message.metadata[SteerKey.steer] = uncertain ? "uncertain" : "failed"
                for key in turns.steers.keys { turns.steers[key]?.bubbles.removeAll { $0 === message } }
                addWarning(error.localizedDescription, in: conversation, after: message)
            }
            objectWillChange.send(); save()
        }
        if slot?.goalAttempt != nil { slot?.guidanceReceipts[message.id] = delivery }
    }

    /// The bubble still belongs to a running turn's steer bookkeeping.
    func steerHeldByTurn(_ bubble: ChatMessage) -> Bool { turns.steers.values.contains { $0.bubbles.contains { $0 === bubble } } }

    /// A queued one-to-one turn owns the rows below its waiting message, including its eventual reply.
    private func insertInActiveTurn(_ message: ChatMessage, in conversation: any Conversation, after active: ChatMessage?, movingFrom index: Int? = nil) {
        var rows = conversation.messages
        let lower = active.flatMap { row in rows.firstIndex { $0 === row } }.map { $0 + 1 } ?? rows.endIndex
        let waiting = conversation is Bot ? rows[lower...].first { $0.metadata[TurnWaitCopy.key] == "waiting" } : nil
        if let index { rows.remove(at: index) }
        let insertion = waiting.flatMap { marker in rows.firstIndex { $0 === marker } }
        rows.insert(message, at: insertion ?? rows.endIndex)
        conversation.messages = rows
    }

    /// Called on new visible output. A receipt alone (or a replay of the same snapshot)
    /// doesn't create a reply. Multiple confirmations before any output share a continuation.
    func continueAfterSteer(origin: ChatMessage, row: ChatMessage) -> ChatMessage? {
        guard row.turnState != .stopped, var pending = turns.steers[origin.id] else { return nil }
        guard let anchor = pending.bubbles.last(where: { $0.metadata[SteerKey.steer] == "delivered" }) else { return nil }
        pending.bubbles.removeAll { $0.metadata[SteerKey.steer] == "delivered" }
        turns.steers[origin.id] = pending.bubbles.isEmpty ? nil : pending

        let conversation = pending.conversation
        guard conversation.messages.contains(where: { $0 === anchor }),
              let index = conversation.messages.firstIndex(where: { $0 === row }) else { return nil }
        let at = now()
        if row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.activity == nil, row.publishedResults == nil, row.attachments.isEmpty {
            // Reuse the empty placeholder, including its ID and original turn start time.
            row.continuedAt = at
            insertInActiveTurn(row, in: conversation, after: row, movingFrom: index)
            return row
        }

        let number = Int(row.metadata[TurnKey.part] ?? "1") ?? 1
        row.metadata[TurnReplyText.origin] = origin.id.uuidString
        row.metadata[TurnKey.part] = String(number)
        row.isStreaming = false; row.turnState = .finished; row.metadata[TurnKey.why] = nil; row.metadata["status"] = nil; row.metadata[TurnKey.agent] = nil
        if var activity = row.activity, activity.current == nil { activity.finish(at: at); row.activity = activity }
        var metadata = [TurnKey.part: String(number + 1), TurnReplyText.origin: origin.id.uuidString]
        metadata[TurnKey.forUser] = row.metadata[TurnKey.forUser]
        metadata[GoalKey.attempt] = row.metadata[GoalKey.attempt]
        metadata[GroupRouting.contextThrough] = row.metadata[GroupRouting.contextThrough]
        let next = ChatMessage(role: .assistant, content: "", createdAt: at, isStreaming: true, metadata: metadata, authorID: row.authorID, turnState: .incomplete)
        insertInActiveTurn(next, in: conversation, after: row)
        turns.parts[origin.id] = next
        runningTurns.values.first { $0.conversation === conversation && $0.assistant === row }?.assistant = next
        return next
    }

    /// Returns the final reply row and settles its steers before the caller saves the turn.
    func endTurnParts(_ assistant: ChatMessage, end: TurnEnd) -> ChatMessage {
        let reply = turns.parts.removeValue(forKey: assistant.id) ?? assistant
        turns.steers[assistant.id] = nil
        return reply
    }
}
