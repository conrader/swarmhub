import Foundation

/// Bubble metadata: `steer` on a queued steer (sent → queued → delivered | failed | resent; failed → next → sentNext
/// after "Send as next message", P32), `correction` on a message sent after the box handed a steer back (followup), or,
/// on rows saved before uxfix1, after its answer was stopped (stopping → stopped). P44: `outOfBand` on a steer read back
/// from the box's history (`OutOfBandMessage`).
enum SteerKey { static let steer = "steer", correction = "correction", outOfBand = "outOfBand" }

/// P28 D2: the plain words.
enum SteerCopy {
    /// Sent before the correction's text (never shown in the bubble).
    static let lead = "(Correction while you were answering:)"
    static let placeholder = "Add to this answer…"
    /// uxfix1: a runtime that cannot steer: the message waits and goes when the answer ends.
    static let queuePlaceholder = "Message (sends when this answer ends)…"
    static let hint = "Your message steers this answer without stopping it; if the answer ends first, it goes as the next message."
    /// The line under a message that waits for the running answer (no steer on this runtime, an install, or attachments).
    static let afterTurn = "Sends when the current answer ends."
    /// The status line under a failed steer: only the reason (the bubble's caption already says "Steer not delivered").
    static let endedFirst = "The answer ended first."
    static let sendAsNext = "Send as next message"

    /// The caption over a steer or correction bubble; nil for any other message.
    static func caption(_ message: ChatMessage, botName: String? = nil) -> String? {
        if message.metadata[SteerKey.outOfBand] != nil, message.metadata[SteerKey.steer] == nil { return OutOfBandMessage.label(botName: botName) }
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
    /// uxfix1-e2e: a tool step ended after the box accepted the steer, so it may have been read with that step's result.
    var stepEndedSinceAccepted = false
    /// Hermes reads a steer only with a tool step's result, else hands it back as `pending_steer`. A steer the box accepted
    /// too late for either (live run, 27 Oct: a text-only reply ended with the steer still queued) was never read: it is
    /// sent as the next message like a handed-back one, never dropped.
    var unread: Bool { returned || (!stepEndedSinceAccepted && bubbles.contains { $0.metadata[SteerKey.steer] == "queued" }) }
}

extension AppStore {
    // MARK: Entry

    /// uxfix1: text typed while this bot's turn streams never stops that turn. It steers it (Hermes `run_steer`, OpenClaw
    /// `queueMode: "steer"`, both read after the current step); what the turn ends before reading the box hands back, and
    /// it goes as the next message (`resendReturnedSteers`). A runtime without steer, an install turn (its own throwaway
    /// session) or a message with attachments waits as the chat's next message and goes when the turn ends.
    func steer(text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = currentConversation(of: bot)
        guard let turn = turn(in: conversation), turn.botID == bot.id else { return false }
        if turn.steerAvailable, attachments.isEmpty, !value.isEmpty, let row = turn.assistant, !Self.isSetupRow(row, in: conversation, bot: bot),
           let activeBackend = try? backend(for: bot) {
            noteFirstSteer()
            deliverSteer(value, into: conversation, sessionID: turnSessionID(turn.token, in: conversation, bot: bot), backend: activeBackend)
            return true
        }
        return queueAfterTurn(text: text, attachments: attachments, bot: bot, conversation: conversation)
    }

    /// uxfix1: the message goes into the chat now and waits there as its next message (`waitForTurn`): it is sent when
    /// the running turn ends, which it never stops. Team threads keep their own controls.
    func queueAfterTurn(text: String, attachments: [ChatAttachment], bot: Bot, conversation: any Conversation) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty, !isTeamThread(conversation),
              !isRetiredWorkflowThread((conversation as? ChatThread)?.id ?? bot.id) else { return false }
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
            turns.steers[origin]?.stepEndedSinceAccepted = false
        }
        objectWillChange.send(); save()
        Task {
            do {
                try await activeBackend.steer(sessionID: sessionID, text: value)
                if message.metadata[SteerKey.steer] == "sent" { message.metadata[SteerKey.steer] = "queued" }
                // uxfix1-e2e: accepted only after its turn ended: the box can no longer read it, so it goes as the next message.
                if activeBackend.kind == .hermes, message.metadata[SteerKey.steer] == "queued", !steerHeldByTurn(message) { sendLateSteer(message, in: conversation) }
            } catch {
                // Already sent again as the next message (the box handed it back first): nothing more to do.
                guard ["sent", "queued"].contains(message.metadata[SteerKey.steer] ?? "") else { return }
                let ended = activeBackend.kind == .hermes && !steerHeldByTurn(message)
                message.metadata[SteerKey.steer] = "failed"
                for key in turns.steers.keys { turns.steers[key]?.bubbles.removeAll { $0 === message } }
                // The run it was meant for is over (the box refuses a steer then): it goes as the next message instead.
                if ended { sendLateSteer(message, in: conversation) } else { addWarning(error.localizedDescription, in: conversation, after: message) }
            }
            objectWillChange.send(); save()
        }
    }

    /// The bubble still belongs to a running turn's steer bookkeeping.
    func steerHeldByTurn(_ bubble: ChatMessage) -> Bool { turns.steers.values.contains { $0.bubbles.contains { $0 === bubble } } }

    /// A steer its turn can no longer read goes as the chat's next message ("Sent after the answer finished").
    private func sendLateSteer(_ bubble: ChatMessage, in conversation: any Conversation) {
        bubble.metadata[SteerKey.steer] = "failed"
        if !sendAsNextMessage(bubble) { addWarning(SteerCopy.endedFirst, in: conversation, after: bubble) }
    }

    /// Stream bookkeeping for queued steers (`consumeTurn`). Returns the row the event belongs in: after a step ended,
    /// the first text or step of a turn holding a queued steer starts a new reply row below the steer bubble (D5).
    func steerRow(for event: AgentEvent, origin: ChatMessage, row: ChatMessage) -> ChatMessage {
        guard var pending = turns.steers[origin.id] else { return row }
        defer { turns.steers[origin.id] = pending.bubbles.isEmpty && !pending.returned ? nil : pending }
        switch event {
        case .steer(.accepted):
            pending.bubbles.filter { $0.metadata[SteerKey.steer] == "sent" }.forEach { $0.metadata[SteerKey.steer] = "queued" }
            pending.stepEndedSinceAccepted = false
            return row
        case .steer(.returned):
            pending.returned = true; return row
        case .tool(let tool) where tool.phase == .completed || tool.phase == .failed:
            // Checked before the event is applied: the step that ends now is the last one running.
            pending.boundary = (row.activity?.steps.filter(\.isRunning).count ?? 0) <= 1; pending.stepEndedSinceAccepted = true; return row
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
        // OpenClaw keeps its own steer queue (`queueMode: "steer"`): only what it handed back is sent again there.
        guard let pending, pending.returned || (bot?.backend == .hermes && pending.unread) else { return }
        // A steer still in flight ("sent") is left to its own answer: a refusal offers "Send as next message".
        let waiting = pending.bubbles.filter { (pending.returned ? ["sent", "queued"] : ["queued"]).contains($0.metadata[SteerKey.steer]) }
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
}
