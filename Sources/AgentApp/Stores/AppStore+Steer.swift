import Foundation

/// P28 D1: how a correction typed during a running turn reaches it. Hermes (`agent.steer`) and OpenClaw (`queueMode:
/// "steer"`) both deliver a steer only after the current tool batch, so a turn that is only writing or thinking never
/// sees it in that answer.
enum SteerRoute: Equatable, Sendable {
    /// A tool step is running: the steer lands after it.
    case queued
    /// No step is running: stop the answer (the partial stays) and send the correction as the next message.
    case stopAndSend

    static func choose(activity: ToolActivity?) -> SteerRoute { activity?.current == nil ? .stopAndSend : .queued }
}

/// Bubble metadata: `steer` on a queued steer (sent → queued → delivered | failed | resent; failed → next → sentNext
/// after "Send as next message", P32), `correction` on a message
/// sent after its answer was stopped (stopping → stopped) or after the box handed a steer back (followup).
enum SteerKey { static let steer = "steer", correction = "correction" }

/// P28 D2: the plain words.
enum SteerCopy {
    /// Sent before the correction's text (never shown in the bubble).
    static let lead = "(Correction while you were answering:)"
    static let placeholder = "Add to this answer…"
    static let hint = "Corrections land after the current step, or stop the answer and continue."
    static let stopFailed = "Couldn't stop the answer, so your correction will land after the current step."
    /// The status line under a failed steer: only the reason (the bubble's caption already says "Steer not delivered").
    static let endedFirst = "The answer ended first."
    static let sendAsNext = "Send as next message"

    /// The caption over a steer or correction bubble; nil for any other message.
    static func caption(_ message: ChatMessage) -> String? {
        switch message.metadata[SteerKey.correction] {
        case "stopping": return "Stopping the answer…"
        case "stopped": return "Stopped the answer and sent your correction"
        case "followup": return "Sent after the answer finished"
        default: break
        }
        switch message.metadata[SteerKey.steer] {
        case nil: return nil
        case "sent": return "Sending…"
        case "queued": return "Delivered after the current step"
        case "failed": return "Steer not delivered"
        case "next": return "Sends as the next message when the answer ends"
        case "sentNext": return "Not delivered as a steer; sent as the next message"
        default: return "Delivered"
        }
    }
}

/// Queued steers of one turn, until a step boundary delivers them or the turn ends (memory only).
struct PendingSteer {
    let conversation: any Conversation
    var bubbles: [ChatMessage] = []
    /// A tool step just ended and no text or step followed yet: the next text is written after the box read the steer.
    var boundary = false
    /// The box handed the text back undelivered (`pending_steer`).
    var returned = false
}

extension AppStore {
    // MARK: Entry

    /// Text typed while this bot's turn streams: queued when a step is running, else Stop and send (D1).
    func steer(text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = currentConversation(of: bot)
        guard let turn = turn(in: conversation), turn.steerAvailable, turn.botID == bot.id else { return false }
        guard attachments.isEmpty else { errorMessage = "Attachments can’t be added to a running turn; send them after it finishes."; return false }
        guard !value.isEmpty, !turns.correcting.contains(turn.token), let row = turn.assistant, let activeBackend = try? backend(for: bot) else { return false }
        noteFirstSteer()
        let sessionID = conversation.hermesSessionID ?? bot.id.uuidString
        switch SteerRoute.choose(activity: row.activity) {
        case .queued: deliverSteer(value, into: conversation, sessionID: sessionID, backend: activeBackend)
        case .stopAndSend: stopAndSend(value, bot: bot, conversation: conversation, turn: turn, sessionID: sessionID, backend: activeBackend)
        }
        return true
    }

    func noteFirstSteer() {
        guard !defaults.bool(forKey: "steerHintShown") else { return }
        defaults.set(true, forKey: "steerHintShown"); steerHint = SteerCopy.hint
    }

    /// The first reply row of `conversation`'s running turn (the key of its steers and parts).
    func streamingTurnOrigin(in conversation: any Conversation) -> UUID? {
        guard let row = turn(in: conversation)?.assistant else { return nil }
        return turns.parts.first { $0.value === row }?.key ?? row.id
    }

    // MARK: Queued

    /// Shows the steer bubble and posts it; it waits for the running step to end. A refusal marks it and says why.
    func deliverSteer(_ value: String, into conversation: any Conversation, sessionID: String, backend activeBackend: any AgentBackend, bubble: ChatMessage? = nil) {
        let message = bubble ?? ChatMessage(role: .user, content: value, metadata: [SteerKey.steer: "sent"])
        if bubble == nil { conversation.messages.append(message) }
        if let origin = streamingTurnOrigin(in: conversation) { turns.steers[origin, default: PendingSteer(conversation: conversation)].bubbles.append(message) }
        objectWillChange.send(); save()
        Task {
            do {
                try await activeBackend.steer(sessionID: sessionID, text: value)
                if message.metadata[SteerKey.steer] == "sent" { message.metadata[SteerKey.steer] = "queued" }
            } catch {
                message.metadata[SteerKey.steer] = "failed"
                for key in turns.steers.keys { turns.steers[key]?.bubbles.removeAll { $0 === message } }
                addWarning(error.localizedDescription, in: conversation, after: message)
            }
            objectWillChange.send(); save()
        }
    }

    /// Stream bookkeeping for queued steers (`consumeTurn`). Returns the row the event belongs in: after a step ended,
    /// the first text or step of a turn holding a queued steer starts a new reply row below the steer bubble (D5).
    func steerRow(for event: AgentEvent, origin: ChatMessage, row: ChatMessage) -> ChatMessage {
        guard var pending = turns.steers[origin.id] else { return row }
        defer { turns.steers[origin.id] = pending.bubbles.isEmpty && !pending.returned ? nil : pending }
        switch event {
        case .steer(.accepted):
            pending.bubbles.filter { $0.metadata[SteerKey.steer] == "sent" }.forEach { $0.metadata[SteerKey.steer] = "queued" }
            return row
        case .steer(.returned):
            pending.returned = true; return row
        case .tool(let tool) where tool.phase == .completed || tool.phase == .failed:
            // Checked before the event is applied: the step that ends now is the last one running.
            pending.boundary = (row.activity?.steps.filter(\.isRunning).count ?? 0) <= 1; return row
        case .tool(let tool) where tool.phase != .started: return row
        case .token, .replace, .tool:
            let boundary = pending.boundary; pending.boundary = false
            let queued = pending.bubbles.filter { $0.metadata[SteerKey.steer] == "queued" }
            guard boundary, let last = queued.last, let index = pending.conversation.messages.firstIndex(where: { $0 === last }) else { return row }
            queued.forEach { $0.metadata[SteerKey.steer] = "delivered" }
            pending.bubbles.removeAll { bubble in queued.contains { $0 === bubble } }
            return split(row, origin: origin, in: pending.conversation, after: index)
        default: return row
        }
    }

    /// Ends `row` as a finished part and opens the next part right after the bubble at `index`.
    private func split(_ row: ChatMessage, origin: ChatMessage, in conversation: any Conversation, after index: Int) -> ChatMessage {
        let number = Int(row.metadata[TurnKey.part] ?? "1") ?? 1
        row.metadata[TurnKey.part] = String(number)
        row.isStreaming = false; row.turnState = .finished; row.metadata[TurnKey.why] = nil; row.metadata["status"] = nil
        if var activity = row.activity { activity.finish(at: now()); row.activity = activity }
        var metadata = [TurnKey.part: String(number + 1)]
        metadata[TurnKey.run] = row.metadata[TurnKey.run]; metadata[TurnKey.forUser] = row.metadata[TurnKey.forUser]
        let next = ChatMessage(role: .assistant, content: "", isStreaming: true, metadata: metadata, authorID: row.authorID, turnState: .incomplete)
        conversation.messages.insert(next, at: index + 1)
        turns.parts[origin.id] = next
        if let turn = turn(in: conversation), turn.assistant === row { turn.assistant = next }
        objectWillChange.send(); save()
        return next
    }

    /// The row the turn that started at `assistant` ended in; clears the turn's steer bookkeeping.
    func endTurnParts(_ assistant: ChatMessage) -> (reply: ChatMessage, steers: PendingSteer?) {
        (turns.parts.removeValue(forKey: assistant.id) ?? assistant, turns.steers.removeValue(forKey: assistant.id))
    }

    /// After a turn: steers the box handed back are sent as the next message of a 1:1 chat or thread; in a group (and
    /// when another turn already runs in that chat) they are marked not delivered. At the turn limit the message waits.
    func resendReturnedSteers(_ pending: PendingSteer?, bot: Bot?) {
        guard let pending, pending.returned else { return }
        let waiting = pending.bubbles.filter { ["sent", "queued"].contains($0.metadata[SteerKey.steer]) }
        guard let last = waiting.last else { return }
        guard let bot, !(pending.conversation is GroupChat), isIdle(pending.conversation), let activeBackend = try? backend(for: bot) else {
            waiting.forEach { $0.metadata[SteerKey.steer] = "failed" }
            addWarning(SteerCopy.endedFirst, in: pending.conversation, after: last); save(); return
        }
        waiting.dropLast().forEach { $0.metadata[SteerKey.steer] = "resent" }
        last.metadata[SteerKey.steer] = nil; last.metadata[SteerKey.correction] = "followup"
        if waiting.count > 1 { last.content = waiting.map(\.content).joined(separator: "\n") }
        startOrWait(bot: bot, conversation: pending.conversation, user: last, backend: activeBackend)
    }

    /// A turn answering `user` (already in the chat), or, at the turn limit, a wait as the chat's next message.
    func startOrWait(bot: Bot, conversation: any Conversation, user: ChatMessage, backend activeBackend: any AgentBackend) {
        if let full = turnCapacityProblem(for: [bot]) { _ = waitForTurn(user, in: conversation, reason: full); return }
        startChatTurn(bot: bot, conversation: conversation, user: user, backend: activeBackend)
    }

    // MARK: Stop and send

    /// Requests Stop for the run first, keeps the partial (stopped), then sends the correction as the next message with a
    /// lead line only the model sees. If Stop fails while the turn still runs, the steer is queued instead (one line says so).
    func stopAndSend(_ value: String, bot: Bot, conversation: any Conversation, turn: ConversationTurn, sessionID: String, backend activeBackend: any AgentBackend) {
        let token = turn.token
        let bubble = ChatMessage(role: .user, content: value, metadata: [SteerKey.correction: "stopping"])
        conversation.messages.append(bubble); objectWillChange.send(); save()
        turns.correcting.insert(token)
        let task = turn.task
        Task {
            defer { turns.correcting.remove(token) }
            do {
                let target = try await activeBackend.stopTarget(sessionID: sessionID)
                _ = try await activeBackend.requestStop(target)
            } catch {
                if isCurrent(token) {
                    bubble.metadata[SteerKey.correction] = nil; bubble.metadata[SteerKey.steer] = "sent"
                    addWarning(SteerCopy.stopFailed, in: conversation, after: bubble)
                    deliverSteer(value, into: conversation, sessionID: sessionID, backend: activeBackend, bubble: bubble)
                    return
                }
            }
            if let current = self.turn(token: token) {
                if let row = current.assistant, row.turnState != .notSent { row.isStreaming = false; row.turnState = .stopped; row.metadata[TurnKey.why] = "stopped" }
                task?.cancel(); didCancelLocalStream?()
            }
            await task?.value
            bubble.metadata[SteerKey.correction] = "stopped"
            guard isIdle(conversation) else { save(); return }
            startOrWait(bot: bot, conversation: conversation, user: bubble, backend: activeBackend)
        }
    }
}
