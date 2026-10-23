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
    /// P28: queued steers per turn (keyed by the turn's first reply row), the row a split turn now streams into, and the
    /// turns whose answer is being stopped for a correction (P39: one per chat, by turn token).
    var steers: [UUID: PendingSteer] = [:]; var parts: [UUID: ChatMessage] = [:]; var correcting: Set<UUID> = []
    /// P32: failed steers sent as the next message once the running turn ends (`AppStore+NextMessage.swift`).
    var nextMessages: [QueuedNextMessage] = []
}

/// P16 Part 2: one stream consumer and one `finishTurn` for both send paths.
extension AppStore {
    /// Reads the stream into `assistant` (and the parts a delivered steer opens after it, `endTurnParts`). Returns how it ended; throws what the backend threw (and cancellation).
    func consumeTurn(_ stream: AsyncThrowingStream<AgentEvent, Error>, assistant: ChatMessage, bot: Bot, sessionID: String, backend activeBackend: any AgentBackend,
                     in conversation: (any Conversation)? = nil, subAgent: (SubAgentTask) -> Void) async throws -> TurnEnd {
        var completed = false; var boxFailure: String?; var sawEvent = false
        // P28 D5: a delivered steer moves the rest of the reply into a new row below its bubble.
        var row = assistant
        for try await event in stream {
            guard !Task.isCancelled else { break }
            #if DEBUG
            if QAMode.enabled { qaEventRecorder?(assistant.id, event) }
            #endif
            if !sawEvent || assistant.metadata[TurnKey.run] == nil {
                sawEvent = true
                if let run = await activeBackend.currentRunID(sessionID: sessionID) { assistant.metadata[TurnKey.run] = run }
            }
            if let conversation = runningTurns.values.first(where: { $0.assistant?.id == assistant.id })?.conversation {
                if isTeamThread(conversation), let run = await activeBackend.currentRunID(sessionID: sessionID) { assistant.metadata[TurnKey.run] = run }
                try noteTeamEvent(in: conversation, assistant: assistant, runID: assistant.metadata[TurnKey.run], event: event)
            }
            row = steerRow(for: event, origin: assistant, row: row)
            switch event {
            case .token(let token):
                row.content += token
                if !token.isEmpty { row.lastTextAt = now() }
                objectWillChange.send(); autosaveIfDue()
            case .replace(let text): row.content = text; row.lastTextAt = text.isEmpty ? nil : now(); objectWillChange.send(); autosaveIfDue()
            case .status(let value): if row.content.isEmpty { row.metadata["status"] = value }
            case .tool(let tool):
                if conversation?.id == bot.id { noteStagedSkillTool(tool, manager: bot); noteSkillDevTool(tool, manager: bot); notePeerEnableTool(tool, manager: bot) }
                if tool.name == "_thinking", tool.phase == .progress { row.lastTextAt = nil }
                if row.content.isEmpty, ToolActivity.isShown(tool.name) { row.metadata["status"] = tool.name }
                let before = row.activity
                // P43: a step remembers where in the text it started, so the reply draws text → steps → text.
                var activity = before ?? ToolActivity(); activity.apply(tool, at: now(), textOffset: row.content.utf16.count)
                noteEndedBotMessageSteps(before: before, after: activity, sender: bot)
                noteStartedBotMessageSteps(before: before, after: activity, sender: bot)
                if activity.total > 0 { row.activity = activity; objectWillChange.send() }
                if tool.phase == .completed || tool.phase == .failed, RoutineWatch.isCronTool(tool.name) { routineToolEnded(bot: bot) }
            case .subAgent(let task): subAgent(task)
            case .approval(var request):
                request.botID = bot.id; request.profile = bot.hermesProfile ?? "default"; request.sessionID = sessionID
                await routeApproval(request, for: bot, backend: activeBackend)
            case .steer: break
            case .appError(let text): if let conversation { addWarning("\(bot.name): \(text)", in: conversation, after: row) }
            case .appNotice(let text): if let conversation { addWarning(text, in: conversation, after: row) }
            case .appUsed(let request, let result):
                if let conversation {
                    let line = ChatMessage(role: .system, content: request, metadata: [TechnicalKey.appRequest: request, TechnicalKey.appResult: result])
                    conversation.messages.insert(line, at: systemIndex(after: row, in: conversation)); objectWillChange.send()
                }
            case .hiddenTokens(let count): assistant.metadata[TurnKey.toolTokens] = String((Int(assistant.metadata[TurnKey.toolTokens] ?? "") ?? 0) + max(0, count))
            case .completed: completed = true
            case .failed(let value): boxFailure = value
            }
        }
        if Task.isCancelled { throw CancellationError() }
        if let boxFailure { return .failedByBox(boxFailure) }
        if completed { return .completed }
        return .endedWithoutTerminal
    }

    /// The one place that decides what the end of a turn means: stamps the row, writes a persisted warning line for every
    /// failure, sets `errorMessage` where it was set before P16 (D3) and starts the cut-turn reconcile. Never deletes a row.
    @discardableResult func finishTurn(_ end: TurnEnd, assistant: ChatMessage, bot: Bot, in conversation: any Conversation, backend activeBackend: (any AgentBackend)?,
                                       alertPrefix: String = "", warn: Bool = true, alert: Bool = true) -> TurnOutcome {
        assistant.isStreaming = false
        // P43: the live "first tool" status ends with the turn.
        assistant.metadata["status"] = nil
        if var activity = assistant.activity { activity.finish(at: now()); assistant.activity = activity }
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
            // Hermes filters its HTTP diagnostics at the transport boundary. Preserve
            // that detail here too, including authentication error codes.
            var text = key.isEmpty ? reason : reason.replacingOccurrences(of: key, with: "[key]")
            if case .error(let error) = end, !(activeBackend is HermesBackend) { text = BotInfoCache.describe(error, key: key) }
            addWarning("\(bot.name): \(text)", in: conversation, after: assistant)
        }
        if case .stopsRest = outcome.round { turns.failureStreak += 1 } else if outcome.state == .finished { noteBoxSuccess() }
        if outcome.state == .incomplete { scheduleCutTurnReconcile(assistant) }
        return outcome
    }

    /// A `.system` warning row after `row` and the system lines already below it (or at the end); an identical line is not
    /// repeated back to back. P52: after those lines, so a failure never reads as earlier than the approval before it.
    func addWarning(_ text: String, in conversation: any Conversation, after row: ChatMessage?) {
        let index = systemIndex(after: row, in: conversation)
        if index > 0, conversation.messages[index - 1].role == .system, conversation.messages[index - 1].content == text { return }
        if index < conversation.messages.endIndex, conversation.messages[index].role == .system, conversation.messages[index].content == text { return }
        conversation.messages.insert(ChatMessage(role: .system, content: text, metadata: [TurnKey.tone: "warning"]), at: index)
        objectWillChange.send()
    }

    /// Where a line about `row`'s turn goes: below `row` and the system lines that follow it (the end without a row).
    func systemIndex(after row: ChatMessage?, in conversation: any Conversation) -> Int {
        guard var index = row.flatMap({ row in conversation.messages.firstIndex { $0.id == row.id } }).map({ $0 + 1 }) else { return conversation.messages.endIndex }
        while index < conversation.messages.endIndex, conversation.messages[index].role == .system { index += 1 }
        return index
    }

    /// The 1:1 and thread turn behind `send(text:)` and Retry: session setup, the stream, `finishTurn`, approvals, release.
    func runChatTurn(bot: Bot, conversation: any Conversation, assistant: ChatMessage, history: [(role: String, content: String)], images: [String],
                     systemPrompt: String, managementText: String? = nil, backend activeBackend: any AgentBackend, token: UUID) async {
        var end: TurnEnd
        let sessionID = conversation.hermesSessionID ?? bot.id.uuidString
        do {
            let workflowThread = isWorkflowThread(conversation)
            if isTeamThread(conversation), try await activeBackend.sessionTransport() != .nativeSessions {
                throw BackendError.unavailable("This backend cannot provide task-specific server sessions. Delegation is waiting.")
            }
            if conversation.hermesSessionID == nil, conversation === bot || workflowThread, try await activeBackend.sessionTransport() == .nativeSessions {
                let note = { [unowned self] (text: String) in insertNote(text, in: conversation, before: assistant) }
                let plan = try await prepareModel(for: bot, backend: activeBackend, note: note)
                // P38 D: a workflow thread is a fresh session of its own, not a fork of the bot's chat.
                let id = workflowThread ? "\(sessionNamespace)agentapp_workflow_\((conversation as? ChatThread)?.id.uuidString.lowercased() ?? "")" : "\(sessionNamespace)agentapp_\(bot.id.uuidString.lowercased())"
                let created = try await activeBackend.createSession(title: workflowThread ? "\(bot.name) · workflow" : bot.name, systemPrompt: bot.persona, id: id)
                if let plan { try await applyModel(plan, bot: bot, sessionID: created, record: !workflowThread, note: note) }
                conversation.hermesSessionID = created
                save()
            }
            let sessionID = conversation.hermesSessionID ?? bot.id.uuidString
            let stream = try await conversationStream(.init(sessionID: sessionID, systemPrompt: withHeartbeatContext(systemPrompt, bot: bot), messages: history, images: images, managementText: managementText),
                                                      bot: bot, backend: activeBackend)
            if isCurrent(token) {
                let flags = try? await activeBackend.features()
                setSteerAvailable(flags?.contains("run_steer") == true, token: token)
                // P12: an OpenClaw link is up only now, so its flags (Reply in thread) are read here too.
                if bot.backend == .openClaw, let flags { botFeatures[bot.id] = flags }
            }
            end = try await consumeTurn(stream, assistant: assistant, bot: bot, sessionID: sessionID, backend: activeBackend, in: conversation) { [unowned self] task in
                upsertSubAgent(task, bot: bot, in: conversation)
            }
        } catch is CancellationError { end = .stoppedByUser
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled { end = .stoppedByUser
        } catch let refusal as ModelRefusal {
            end = .error(refusal)
        } catch { end = .error(error) }
        if Task.isCancelled { end = .stoppedByUser }
        if let task = teamWorkflow(in: conversation)?.tasks.first(where: { $0.threadID == conversation.id }), task.delivery?.submissionStarted == true,
           case .error(let error) = end {
            // A wrapper/protocol error after submission is not proof of a rejected request.
            end = .error(StreamBreak(delivered: true, underlying: error))
        }
        let (assistant, steers) = endTurnParts(assistant)
        let cancelled: Bool; if case .stoppedByUser = end { cancelled = true } else { cancelled = false }
        if cancelled, assistant.turnState != .stopped { assistant.turnState = .stopped }
        let outcome = finishTurn(end, assistant: assistant, bot: bot, in: conversation, backend: activeBackend)
        // P54: a turn that still ends with an app request shows it folded (P51) with this line: never raw, never silent.
        if TechnicalRow.isAppRequest(assistant.content) { addWarning(AppRequestMarker.notRun, in: conversation, after: assistant) }
        let abandoned = approvals.filter { !$0.isManaged && $0.botID == bot.id && ($0.sessionID == nil || $0.sessionID == (conversation.hermesSessionID ?? sessionID)) }
        for approval in abandoned {
            appendAudit(to: bot, approval: approval, outcome: .denied, decidedBy: "system", reason: cancelled ? "Run stopped; pending approval was cancelled." : "Run ended; pending approval was cancelled.")
        }
        approvals.removeAll { abandoned.map(\.id).contains($0.id) }
        endTurn(token)
        save()
        #if DEBUG
        if QAMode.enabled { return }
        #endif
        let hasText = !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if outcome.state == .finished {
            if !isTeamThread(conversation) { handleManagerReply(assistant, from: bot, in: conversation); handleReportOps(assistant, from: bot); refreshModelsAfterRecipe(assistant, from: bot, in: conversation) }
            startReviewIfNeeded(assistant, from: bot, in: conversation)
            if conversation === bot { afterSuggestionTurn(bot: bot, reply: assistant) }
        }
        if conversation.id == bot.id { finishStagedSkillInstall(manager: bot, end: end); finishSkillInstallChecks(manager: bot, reply: assistant, end: end) }
        if outcome.state == .finished && hasText && !SilentReply.isSilent(SwarmhubBlock.visibleText(assistant.finalText)) {
            AvatarReactions.shared.completed(bot)
            if !isTeamThread(conversation) { notifyIfNeeded(bot: bot, message: technicalLine(assistant, botName: bot.name)) }
        }
        // P45: a stop for a typed correction (P28) is not the user stopping the goal; the correction's own turn continues it.
        let corrected = turns.correcting.contains(token)
        resendReturnedSteers(steers, bot: bot)
        sendQueuedNextMessage()
        if outcome.state == .finished {
            // Gap closures after live pass 4: managed approvals become cards; a secret request opens the entry sheet.
            routeManagedApprovals(in: assistant, bot: bot)
            routeSecretRequests(in: assistant, bot: bot, conversation: conversation)
        }
        automationTurnEnded(in: conversation, bot: bot, reply: assistant, outcome: outcome, corrected: corrected)
        if conversation.id == bot.id { continueAllBotsSkillInstall(manager: bot, end: end, token: token) }
    }

    /// History for a 1:1 turn: the transcript up to and including `last`, without steer bubbles, warning lines and empty replies.
    func chatHistory(_ conversation: any Conversation, upTo last: ChatMessage? = nil, excluding reply: ChatMessage) -> [(role: String, content: String)] {
        var rows = owner(of: conversation).map { readableMessages(conversation.messages, for: $0.id) } ?? conversation.messages
        if let last, let index = rows.firstIndex(where: { $0.id == last.id }) { rows = Array(rows[...index]) }
        return rows.filter { $0.id != reply.id && !$0.isSteer && $0.metadata[TurnKey.tone] != "warning" && $0.metadata[SlashKey.line] == nil && $0.metadata[TechnicalKey.appRequest] == nil && $0.presentation != .automation && !($0.role == .assistant && $0.turnState != nil && $0.content.isEmpty) }
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
    func flushNow() { suspendTeamClock(); save() }

    func noteBoxSuccess() {
        guard turns.failureStreak > 0 else { return }
        turns.failureStreak = 0
        reconcileAttention(reason: .recovered)
    }
}
