import Foundation

/// Bubble metadata: `steer` on a queued steer (sent → queued → delivered | failed; failed → next → sentNext after
/// "Send as next message"), `correction` on a message that an older build sent after a steer was handed back.
enum SteerKey { static let steer = "steer", correction = "correction" }

/// The plain words.
enum SteerCopy {
    /// Sent before the correction's text (never shown in the bubble).
    static let lead = "(Correction while you were answering:)"
    static let placeholder = "Add to this answer…"
    /// An agent that cannot steer: the message waits and goes when the answer ends.
    static let queuePlaceholder = "Message (sends when this answer ends)…"
    static let hint = "Your message goes into this answer without stopping it. If the answer ends first, it is sent as your next message."
    /// The line under a message that waits for the running answer (no steer for this bot, or attachments).
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
        case "sent": return "Sending…"
        case "queued": return "Delivered after the current step"
        case "failed": return "Not delivered"
        case "next": return "Sends as the next message when the answer ends"
        case "sentNext": return "It did not get into that answer, so it was sent as your next message"
        default: return "Delivered"
        }
    }
}

/// Queued steers of one turn, until a step boundary delivers them or the turn ends (memory only).
struct PendingSteer {
    let conversation: any Conversation
    var bubbles: [ChatMessage] = []
    /// A tool step just ended and no text or step followed yet: the next text is written after the agent read the steer.
    var boundary = false
}

extension AppStore {
    // MARK: Entry

    /// Text typed while this bot's turn streams never stops that turn. It steers it (typed into the running agent, which
    /// reads it as soon as it can). A bot that holds messages, or a message with attachments, waits as the chat's next
    /// message and goes when the turn ends.
    func steer(text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let turn = turn(in: bot), turn.botID == bot.id else { return false }
        if turn.steerAvailable, attachments.isEmpty, !value.isEmpty, turn.assistant != nil, let activeBackend = try? backend(for: bot) {
            noteFirstSteer()
            deliverSteer(value, into: bot, sessionID: turnSessionID(in: bot, bot: bot), backend: activeBackend)
            return true
        }
        return queueAfterTurn(text: text, attachments: attachments, bot: bot, conversation: bot)
    }

    /// The message goes into the chat now and waits there as its next message (`waitForTurn`): it is sent when the
    /// running turn ends, which it never stops.
    func queueAfterTurn(text: String, attachments: [ChatAttachment], bot: Bot, conversation: any Conversation) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        let user = ChatMessage(role: .user, content: text, replyToID: replyTo?.id, attachments: attachments)
        do {
            try validateArtifactAccess(user, botID: bot.id)
            _ = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:))
        } catch { errorMessage = error.localizedDescription; return false }
        steerHint = nil
        captureAttachments(user, readers: [bot.id])
        conversation.messages.append(user)
        return waitForTurn(user, in: conversation, reason: SteerCopy.afterTurn)
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
        if let origin = streamingTurnOrigin(in: conversation) {
            turns.steers[origin, default: PendingSteer(conversation: conversation)].bubbles.append(message)
        }
        objectWillChange.send(); save()
        Task {
            do {
                try await activeBackend.steer(sessionID: sessionID, text: value)
                if message.metadata[SteerKey.steer] == "sent" { message.metadata[SteerKey.steer] = "queued" }
            } catch {
                guard ["sent", "queued"].contains(message.metadata[SteerKey.steer] ?? "") else { return }
                // The agent says there is no run to steer any more: nothing was typed, so the text goes as the next message.
                let refused = Self.runTakesNoSteer(error)
                message.metadata[SteerKey.steer] = "failed"
                for key in turns.steers.keys { turns.steers[key]?.bubbles.removeAll { $0 === message } }
                // Never after the user's Stop: then it is only offered ("Send as next message").
                if refused, !turns.stoppedSteers.contains(message.id), turn(in: conversation)?.stopping != true {
                    sendLateSteer(message, in: conversation)
                } else if !refused { addWarning(error.localizedDescription, in: conversation, after: message) }
            }
            objectWillChange.send(); save()
        }
    }

    /// The bubble still belongs to a running turn's steer bookkeeping.
    func steerHeldByTurn(_ bubble: ChatMessage) -> Bool { turns.steers.values.contains { $0.bubbles.contains { $0 === bubble } } }

    /// A steer its turn can no longer read goes as the chat's next message ("Sent after the answer finished").
    private func sendLateSteer(_ bubble: ChatMessage, in conversation: any Conversation) {
        bubble.metadata[SteerKey.steer] = "failed"
        if !sendAsNextMessage(bubble, automatic: true) { addWarning(SteerCopy.endedFirst, in: conversation, after: bubble) }
    }

    /// Refusals that mean there is no run to take the text: `run_not_found` (the agent is not running). Anything else
    /// (a 500, a network drop) is shown.
    nonisolated static func runTakesNoSteer(_ error: Error) -> Bool {
        if case BackendError.http(let code, let text) = error { return (code == 409 || code == 404) && text.contains("run_not_found") }
        return false
    }

    /// The user's Stop: the turn's unsent steers, and the ones already waiting by themselves as its next message,
    /// are only offered from now on (`Send as next message`), never sent by themselves.
    func holdSteersAtStop(in conversation: any Conversation, origin: UUID?) {
        if let origin, let pending = turns.steers[origin] { pending.bubbles.forEach { turns.stoppedSteers.insert($0.id) } }
        let automatic = turns.nextMessages.filter { $0.automatic && $0.conversation === conversation && !$0.restored }
        turns.nextMessages.removeAll { next in automatic.contains { $0.id == next.id } }
        automatic.forEach { turns.stoppedSteers.insert($0.bubble.id); giveBack($0) }
    }

    /// Stream bookkeeping for queued steers (`consumeTurn`). Returns the row the event belongs in: after a step ended,
    /// the first text or step of a turn holding a queued steer starts a new reply row below the steer bubble (D5).
    func steerRow(for event: AgentEvent, origin: ChatMessage, row: ChatMessage) -> ChatMessage {
        guard var pending = turns.steers[origin.id] else { return row }
        defer { turns.steers[origin.id] = pending.bubbles.isEmpty ? nil : pending }
        switch event {
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
        row.isStreaming = false; row.turnState = .finished; row.metadata[TurnKey.why] = nil; row.metadata["status"] = nil; row.metadata[TurnKey.agent] = nil
        if var activity = row.activity { activity.finish(at: now()); row.activity = activity }
        var metadata = [TurnKey.part: String(number + 1)]
        metadata[TurnKey.forUser] = row.metadata[TurnKey.forUser]
        let next = ChatMessage(role: .assistant, content: "", isStreaming: true, metadata: metadata, authorID: row.authorID, turnState: .incomplete)
        conversation.messages.insert(next, at: index + 1)
        turns.parts[origin.id] = next
        if let turn = turn(in: conversation), turn.assistant === row { turn.assistant = next }
        objectWillChange.send(); save()
        return next
    }

    /// The row the turn that started at `assistant` ended in; clears the turn's steer bookkeeping.
    func endTurnParts(_ assistant: ChatMessage) -> ChatMessage {
        turns.steers[assistant.id] = nil
        return turns.parts.removeValue(forKey: assistant.id) ?? assistant
    }
}
