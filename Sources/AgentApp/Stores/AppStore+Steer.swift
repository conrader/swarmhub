import Foundation

/// A steer keeps its receipt until an explicit resend converts its row to a normal user message.
enum SteerKey { static let steer = "steer", correction = "correction", explicitNext = "explicitNext" }

/// The plain words.
enum SteerCopy {
    /// Sent before the correction's text (never shown in the bubble).
    static let lead = "(Correction while you were answering:)"
    static let startupWait = "Waiting for the bot to start. If this answer cannot take follow-ups, this sends next."
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
        case nil: return message.metadata[SteerKey.explicitNext] == "1" ? "Requested as the next message" : nil
        case "sent": return "Sending to the current answer…"
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
        guard turn.steerAvailable, !turn.stopping, let backend = turn.backend, turn.assistant != nil else {
            conversation.messages.append(message)
            let target = turn.awaitingSteerCapability && !turn.stopping ? turn.startupTarget : nil
            if !waitForTurn(message, in: conversation, reason: target == nil ? TurnWaitCopy.afterAnswer : SteerCopy.startupWait, startupTarget: target) {
                // Other recipients in a group send may already have accepted their copies.
                guard conversation is GroupChat else { return false }
                message.metadata[SteerKey.steer] = "failed"
                conversation.messages.append(message)
                addWarning("The message could not be queued.", in: conversation, after: message)
                save()
            }
            return true
        }
        insertInActiveTurn(message, in: conversation, after: turn.assistant)
        noteFirstSteer()
        message.metadata[SteerKey.steer] = "sent"
        deliverSteer(message.modelText.trimmingCharacters(in: .whitespacesAndNewlines), into: conversation,
                     sessionID: turnSessionID(in: conversation, bot: bot), backend: backend, bubble: message, files: files, slot: turn)
        return true
    }

    /// A workspace without live steering keeps the original queue entry and its recipient.
    func keepStartupFollowUpsQueued(for turn: ConversationTurn) {
        guard let target = turn.startupTarget else { return }
        for index in turns.nextMessages.indices where turns.nextMessages[index].startupTarget == target {
            let next = turns.nextMessages[index]
            turns.nextMessages[index].startupTarget = nil
            let rows = next.conversation.messages
            if let position = rows.firstIndex(where: { $0 === next.bubble }),
               rows.indices.contains(position + 1), rows[position + 1].metadata[TurnWaitCopy.key] == "line" {
                rows[position + 1].content = TurnWaitCopy.afterAnswer
            }
        }
    }

    func deliverStartupFollowUps(to bot: Bot, turn: ConversationTurn) {
        guard !turn.stopping, let backend = turn.backend, let reply = turn.assistant, let target = turn.startupTarget else { return }
        let conversation = turn.conversation
        for next in turns.nextMessages where next.startupTarget == target && next.conversation === conversation {
            let message = next.bubble
            guard let index = conversation.messages.firstIndex(where: { $0 === message }),
                  recordNextMessage(next, .submitting) else { return }
            turns.nextMessages.removeAll { $0.id == next.id }
            endWait(message, in: conversation)
            do {
                let files = try message.attachments.map(attachmentEncoder.taskFile(for:))
                insertInActiveTurn(message, in: conversation, after: reply, movingFrom: index)
                message.metadata[SteerKey.steer] = "sent"
                deliverSteer(message.modelText.trimmingCharacters(in: .whitespacesAndNewlines), into: conversation,
                             sessionID: turnSessionID(in: conversation, bot: bot), backend: backend, bubble: message,
                             files: files, slot: turn, queued: next)
            } catch {
                message.metadata[SteerKey.steer] = "failed"
                addWarning(error.localizedDescription, in: conversation, after: message)
                save()
                if !turns.saveFailing { recordNextMessage(next, .removed) }
            }
        }
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
    func deliverSteer(_ value: String, into conversation: any Conversation, sessionID: String, backend activeBackend: any AgentBackend, bubble: ChatMessage? = nil, files: [HerdrClient.TaskFile] = [], slot: ConversationTurn? = nil, queued: QueuedNextMessage? = nil) {
        let message = bubble ?? ChatMessage(role: .user, content: value, metadata: [SteerKey.steer: "sent"])
        let slot = slot ?? turn(in: conversation)
        if bubble == nil { insertInActiveTurn(message, in: conversation, after: slot?.assistant) }
        let recipient = slot?.botID
        if let origin = steerOrigin(slot) {
            message.metadata[TurnReplyText.origin] = origin.uuidString
            turns.steers[origin, default: PendingSteer(conversation: conversation)].bubbles.append(message)
        }
        let goalID = (conversation as? Bot)?.goal.flatMap { $0.state.active ? $0.id : nil }
        turns.inFlightSteers.insert(message.id)
        objectWillChange.send(); save()
        let preceding = slot?.lastSteerDelivery
        let delivery = Task {
            await preceding?.value
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
            if let queued, !turns.saveFailing { recordNextMessage(queued, .sent) }
        }
        slot?.lastSteerDelivery = delivery
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
        let next = replyPartAfterGuidance(row, origin: origin.id.uuidString, at: now())
        insertInActiveTurn(next, in: conversation, after: row, movingFrom: next === row ? index : nil)
        if next !== row {
            turns.parts[origin.id] = next
            runningTurns.values.first { $0.conversation === conversation && $0.assistant === row }?.assistant = next
        }
        return next
    }

    /// Live and restored turns use the same part IDs, tool history and delivery receipt.
    func replyPartAfterGuidance(_ row: ChatMessage, origin: String, at: Date) -> ChatMessage {
        if row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.activity == nil, row.publishedResults == nil, row.attachments.isEmpty {
            row.continuedAt = at
            return row
        }

        let number = Int(row.metadata[TurnKey.part] ?? "1") ?? 1
        row.metadata[TurnReplyText.origin] = origin
        row.metadata[TurnKey.part] = String(number)
        row.isStreaming = false; row.turnState = .finished; row.metadata[TurnKey.why] = nil; row.metadata["status"] = nil; row.metadata[TurnKey.agent] = nil
        if var activity = row.activity, activity.current == nil { activity.finish(at: at); row.activity = activity }
        var metadata = [TurnKey.part: String(number + 1), TurnReplyText.origin: origin]
        metadata[TurnKey.forUser] = row.metadata[TurnKey.forUser]
        metadata[GoalKey.attempt] = row.metadata[GoalKey.attempt]
        metadata[GroupRouting.contextThrough] = row.metadata[GroupRouting.contextThrough]
        let next = ChatMessage(role: .assistant, content: "", createdAt: at, isStreaming: true, metadata: metadata, authorID: row.authorID, turnState: .incomplete)
        next.deliveryReceipt = row.deliveryReceipt
        row.deliveryReceipt = nil
        return next
    }

    /// Returns the final reply row and settles its steers before the caller saves the turn.
    func endTurnParts(_ assistant: ChatMessage, end: TurnEnd) -> ChatMessage {
        let reply = turns.parts.removeValue(forKey: assistant.id) ?? assistant
        turns.steers[assistant.id] = nil
        return reply
    }
}
