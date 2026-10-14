import Foundation

/// P16 runtime bookkeeping that lives beside the store (memory only).
@MainActor final class TurnBook {
    /// Retry guard: `conversation|member|user row id` while an attempt runs.
    var retryLedger: Set<String> = []
    /// Cut-turn reconcile schedules per reply row.
    var schedules: [UUID: Task<Void, Never>] = [:]
    /// The last automatic pass per session key, and the passes running now.
    var lastPass: [String: ContinuousClock.Instant] = [:]; var running: Set<String> = []
    /// Throttled token autosave.
    var lastAutosave: ContinuousClock.Instant?
    /// Failed box calls since the last success (the first success after a streak reconciles).
    var failureStreak = 0
    /// `save()` failures are reported once per streak.
    var saveFailing = false
    /// Launch work runs once per process; groups that had a round on disk when the store was decoded.
    var didLaunchRecovery = false; var roundsAtLaunch: Set<UUID> = []
    var pathDown = false
    var connectivityTask: Task<Void, Never>?; var terminateObserver: NSObjectProtocol?
}

/// P16 Part 2: one stream consumer and one `finishTurn` for both send paths.
extension AppStore {
    /// Reads the stream into `assistant`. Returns how it ended; throws what the backend threw (and cancellation).
    func consumeTurn(_ stream: AsyncThrowingStream<AgentEvent, Error>, assistant: ChatMessage, bot: Bot, sessionID: String, backend activeBackend: any AgentBackend,
                     subAgent: (SubAgentTask) -> Void) async throws -> TurnEnd {
        var completed = false; var boxFailure: String?; var sawEvent = false
        for try await event in stream {
            guard !Task.isCancelled else { break }
            if !sawEvent {
                sawEvent = true
                if let run = await activeBackend.currentRunID(sessionID: sessionID) { assistant.metadata[TurnKey.run] = run }
            }
            switch event {
            case .token(let token): assistant.content += token; objectWillChange.send(); autosaveIfDue()
            case .status(let value): if assistant.content.isEmpty { assistant.metadata["status"] = value }
            case .subAgent(let task): subAgent(task)
            case .approval(var request):
                request.botID = bot.id; request.profile = bot.hermesProfile ?? "default"; request.sessionID = sessionID
                await routeApproval(request, for: bot, backend: activeBackend)
            case .completed: completed = true
            case .failed(let value): boxFailure = value
            }
        }
        if Task.isCancelled { throw CancellationError() }
        if completed { return .completed }
        if let boxFailure { return .failedByBox(boxFailure) }
        return .endedWithoutTerminal
    }

    /// The one place that decides what the end of a turn means: stamps the row, writes a persisted warning line for every
    /// failure, sets `errorMessage` where it was set before P16 (D3) and starts the cut-turn reconcile. Never deletes a row.
    @discardableResult func finishTurn(_ end: TurnEnd, assistant: ChatMessage, bot: Bot, in conversation: any Conversation, backend activeBackend: (any AgentBackend)?,
                                       alertPrefix: String = "", warn: Bool = true, alert: Bool = true) -> TurnOutcome {
        assistant.isStreaming = false
        if assistant.turnState == .stopped { return TurnOutcome.classify(.stoppedByUser) }
        let outcome = TurnOutcome.classify(end)
        assistant.turnState = outcome.state
        assistant.metadata[TurnKey.why] = outcome.state == .finished ? nil : outcome.why
        assistant.metadata[TurnKey.ambiguous] = outcome.ambiguous ? "1" : nil
        let key = (activeBackend as? HermesBackend)?.apiKey ?? ""
        switch end {
        case .failedByBox(let text) where alert: errorMessage = alertPrefix + text
        case .error(let error) where alert: errorMessage = alertPrefix + error.localizedDescription
        default: break
        }
        if warn, let reason = outcome.reason {
            let text: String
            if case .error(let error) = end { text = BotInfoCache.describe(error, key: key) } else { text = key.isEmpty ? reason : reason.replacingOccurrences(of: key, with: "[key]") }
            addWarning("\(bot.name): \(text)", in: conversation, after: assistant)
        }
        if case .stopsRest = outcome.round { turns.failureStreak += 1 } else if outcome.state == .finished { noteBoxSuccess() }
        if outcome.state == .incomplete { scheduleCutTurnReconcile(assistant) }
        return outcome
    }

    /// A `.system` warning row after `row` (or at the end); an identical line is not repeated back to back.
    func addWarning(_ text: String, in conversation: any Conversation, after row: ChatMessage?) {
        let index = row.flatMap { row in conversation.messages.firstIndex { $0.id == row.id } }.map { $0 + 1 } ?? conversation.messages.endIndex
        if index > 0, conversation.messages[index - 1].role == .system, conversation.messages[index - 1].content == text { return }
        if index < conversation.messages.endIndex, conversation.messages[index].role == .system, conversation.messages[index].content == text { return }
        conversation.messages.insert(ChatMessage(role: .system, content: text, metadata: [TurnKey.tone: "warning"]), at: index)
        objectWillChange.send()
    }

    /// The 1:1 and thread turn behind `send(text:)` and Retry: session setup, the stream, `finishTurn`, approvals, release.
    func runChatTurn(bot: Bot, conversation: any Conversation, assistant: ChatMessage, history: [(role: String, content: String)], images: [String],
                     systemPrompt: String, backend activeBackend: any AgentBackend, token: UUID) async {
        var end: TurnEnd
        let sessionID = conversation.hermesSessionID ?? bot.id.uuidString
        do {
            if conversation.hermesSessionID == nil, conversation === bot, try await activeBackend.sessionTransport() == .nativeSessions {
                let note = { [unowned self] (text: String) in insertNote(text, in: bot, before: assistant) }
                let plan = try await prepareModel(for: bot, backend: activeBackend, note: note)
                let created = try await activeBackend.createSession(title: bot.name, systemPrompt: bot.persona, id: "\(sessionNamespace)agentapp_\(bot.id.uuidString.lowercased())")
                if let plan { try await applyModel(plan, bot: bot, sessionID: created, record: true, note: note) }
                conversation.hermesSessionID = created
                save()
            }
            let sessionID = conversation.hermesSessionID ?? bot.id.uuidString
            let stream = try await activeBackend.send(.init(sessionID: sessionID, systemPrompt: systemPrompt, messages: history, images: images))
            if activeStreamToken == token { steerAvailable = (try? await activeBackend.features())?.contains("run_steer") == true }
            end = try await consumeTurn(stream, assistant: assistant, bot: bot, sessionID: sessionID, backend: activeBackend) { [unowned self] task in
                subAgentTasks[bot.id, default: []].append(task)
                conversation.messages.append(ChatMessage(role: .assistant, content: task.title, presentation: .delegation, metadata: ["detail": task.detail, "status": task.status.rawValue]))
            }
        } catch is CancellationError { end = .stoppedByUser
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled { end = .stoppedByUser
        } catch let refusal as ModelRefusal {
            end = .error(refusal)
        } catch { end = .error(error) }
        if Task.isCancelled { end = .stoppedByUser }
        let cancelled: Bool; if case .stoppedByUser = end { cancelled = true } else { cancelled = false }
        if cancelled, assistant.turnState != .stopped { assistant.turnState = .stopped }
        let outcome = finishTurn(end, assistant: assistant, bot: bot, in: conversation, backend: activeBackend)
        let abandoned = approvals.filter { $0.botID == bot.id && ($0.sessionID == nil || $0.sessionID == (conversation.hermesSessionID ?? sessionID)) }
        for approval in abandoned {
            appendAudit(to: bot, approval: approval, outcome: .denied, decidedBy: "system", reason: cancelled ? "Run stopped; pending approval was cancelled." : "Run ended; pending approval was cancelled.")
        }
        approvals.removeAll { abandoned.map(\.id).contains($0.id) }
        if activeStreamToken == token {
            isStreaming = false; streamTask = nil; activeStreamToken = nil; streamingBotID = nil; streamingAssistant = nil; streamingConversation = nil; steerAvailable = false
        }
        save()
        let hasText = !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if outcome.state == .finished { handleManagerReply(assistant, from: bot, in: conversation) }
        if outcome.state == .finished && hasText {
            AvatarReactions.shared.completed(bot)
            notifyIfNeeded(bot: bot, message: SwarmhubBlock.visibleText(assistant.content))
        }
    }

    /// History for a 1:1 turn: the transcript up to and including `last`, without steer bubbles, warning lines and empty replies.
    func chatHistory(_ conversation: any Conversation, upTo last: ChatMessage? = nil, excluding reply: ChatMessage) -> [(role: String, content: String)] {
        var rows = conversation.messages
        if let last, let index = rows.firstIndex(where: { $0.id == last.id }) { rows = Array(rows[...index]) }
        return rows.filter { $0.id != reply.id && !$0.isSteer && $0.metadata[TurnKey.tone] != "warning" && !($0.role == .assistant && $0.turnState != nil && $0.content.isEmpty) }
            .map { (role: $0.role.rawValue, content: $0.outgoingText) }
    }

    // MARK: Saves

    /// Token appends save at most every `autosaveInterval`; the row is `incomplete` on disk throughout.
    func autosaveIfDue() {
        let now = ContinuousClock.now
        if let last = turns.lastAutosave, now - last < autosaveInterval { return }
        turns.lastAutosave = now; save()
    }

    /// Terminate and sleep: write at once.
    func flushNow() { save() }

    func noteBoxSuccess() {
        guard turns.failureStreak > 0 else { return }
        turns.failureStreak = 0
        reconcileAttention(reason: .recovered)
    }
}
