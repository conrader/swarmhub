import Foundation

/// P16 runtime bookkeeping that lives beside the store (memory only).
@MainActor final class TurnBook {
    /// Only goals explicitly started here or reconciled on launch may dispatch.
    var checkingGoalSpend: Set<UUID> = []
    var scheduledGoals: Set<UUID> = []
    /// Older ordinary stops may finish after their local stream releases the slot.
    var pendingInterrupts: [UUID: Set<UUID>] = [:]
    var textBuffers: [UUID: TurnTextBuffer] = [:]
    /// Retry guard: `conversation|member|user row id` while an attempt runs.
    var retryLedger: Set<String> = []
    /// Throttled token autosave.
    var lastAutosave: ContinuousClock.Instant?
    /// Failed turns since the last success.
    var failureStreak = 0
    /// `save()` failures are reported once per streak.
    var saveFailing = false
    /// Launch work runs once per process; groups that had a round on disk when the store was decoded.
    var didLaunchRecovery = false; var roundsAtLaunch: Set<UUID> = []
    var pathDown = false
    var connectivityTask: Task<Void, Never>?; var terminateObserver: NSObjectProtocol?
    /// P28: queued steers per turn (keyed by the turn's first reply row) and the row a split turn now streams into.
    var steers: [UUID: PendingSteer] = [:]; var parts: [UUID: ChatMessage] = [:]
    /// Requests still awaiting a delivery result, including after their turn ends.
    var inFlightSteers: Set<UUID> = []
    /// P32: failed steers sent as the next message once the running turn ends (`AppStore+NextMessage.swift`).
    var nextMessages: [QueuedNextMessage] = []
    var checkingPromptQueues: Set<UUID> = []
}

/// One stream consumer and one `finishTurn` for both send paths (a bot's chat and a group).
extension AppStore {
    /// Reads the stream into `assistant` (and the parts a delivered steer opens after it, `endTurnParts`). Returns how it ended; throws what the backend threw (and cancellation).
    func consumeTurn(_ stream: AsyncThrowingStream<AgentEvent, Error>, assistant: ChatMessage, bot: Bot, group: GroupChat? = nil, cumulativeReplacements: Bool = false) async throws -> TurnEnd {
        var completed = false; var failure: String?
        var sessionModel: (name: String, source: RunSummary.ModelSource)?
        var finalJournal: String?
        var activitySummary: (seconds: Int, tools: Int)?
        // A delivered steer moves the rest of the reply into a new row below its bubble.
        var row = assistant
        // A final snapshot may only finish a word or add punctuation. Show that edit
        // on the draft until more text establishes that a continuation really began.
        var singleEdit: (before: String, after: String)?
        // A tool can finish after text has crossed a receipt. Update the part that owns its start.
        var earlierParts: [ChatMessage] = []
        defer {
            for part in earlierParts where part.activity?.current != nil {
                part.activity?.finish(at: now())
            }
        }
        // What the agent's server says the turn is waiting for; it goes with the reply into each new part.
        var agentStatus: String?
        let bufferID = group == nil ? bot.id : assistant.id
        let buffer = TurnTextBuffer { orderChanged in
            if let group { group.objectWillChange.send() } else { bot.objectWillChange.send() }
            if orderChanged { self.objectWillChange.send() }
        }
        turns.textBuffers[bufferID] = buffer
        defer { buffer.flush(); turns.textBuffers.removeValue(forKey: bufferID) }
        for try await event in stream {
            if row.metadata[GoalKey.attempt] != nil && (Task.isCancelled || row.turnState == .stopped) { break }
            try Task.checkCancellation()
            if assistant.turnState == .stopped || row.turnState == .stopped { continue }
            // Herdr emits the journal IDs just before its final snapshot. An intervening save
            // must not mark a draft as already containing the final journal text.
            let savedSnapshot = finalJournal != nil
            if case .replace = event, let ids = finalJournal {
                assistant.metadata["herdrJournal"] = ids
                finalJournal = nil
            }
            var continued = false
            let pending = turns.steers[assistant.id]?.bubbles.contains { $0.metadata[SteerKey.steer] == "delivered" } == true
            // Anything the server sends again ends a reconnect.
            if case .status = event {} else if row.metadata[TurnKey.reconnecting] != nil { row.metadata[TurnKey.reconnecting] = nil; objectWillChange.send() }
            // Batch ordinary output. Reconcile receipts and cumulative snapshots only
            // after all text preceding the boundary has reached its transcript row.
            if !pending {
                if row.metadata[TurnKey.agent] != agentStatus { row.metadata[TurnKey.agent] = agentStatus }
                switch event {
                case .token(let text):
                    buffer.receive(text, replacing: false, row: row, at: now())
                    autosaveIfDue()
                    continue
                case .replace(let text) where earlierParts.isEmpty:
                    buffer.receive(text, replacing: true, row: row, at: now())
                    autosaveIfDue()
                    continue
                default: break
                }
            }
            buffer.flush()
            var addition = ""
            switch event {
            case .token(let token): addition = token
            case .replace(let text):
                addition = TurnReplyText.replace(text, parts: earlierParts + [row],
                    cumulative: cumulativeReplacements, saved: savedSnapshot, pending: pending)
            default: break
            }
            if pending {
                var hasNewOutput: Bool
                switch event {
                case .replace, .token:
                    if let edit = singleEdit, row.content != edit.after { singleEdit = nil }
                    if let edit = singleEdit, !addition.isEmpty {
                        addition = String(edit.after.dropFirst(edit.before.count)) + addition
                        row.content = edit.before
                        singleEdit = nil
                    } else if case .replace = event, addition.count == 1, !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let before = row.content
                        row.content += addition
                        singleEdit = (before, row.content)
                        addition = ""
                    }
                    if !addition.isEmpty {
                        let text = row.content + addition
                        let cut = ChatCardParser.steerBoundary(in: text, after: row.content) ?? text.endIndex
                        row.content = String(text[..<cut])
                        addition = String(text[cut...])
                    }
                    hasNewOutput = !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .tool(let tool):
                    hasNewOutput = tool.phase == .started && ToolActivity.isShown(tool.name)
                        && !(tool.callID.map { id in row.activity?.steps.contains { $0.callID == id } == true } ?? false)
                case .published(_, let result):
                    hasNewOutput = row.publishedResults?.items.contains { $0.id == result.id } != true
                default: hasNewOutput = false
                }
                if hasNewOutput, addition.isEmpty, ChatCardParser.steerBoundary(in: row.content, after: row.content) == nil {
                    hasNewOutput = false
                }
                if hasNewOutput, cumulativeReplacements, !addition.isEmpty {
                    TurnReplyText.carryOpenParagraph(from: row, into: &addition)
                }
                if hasNewOutput, let next = continueAfterSteer(origin: assistant, row: row) {
                    if next !== row {
                        earlierParts.append(row)
                    }
                    row = next
                    singleEdit = nil
                    continued = true
                }
            }
            if row.metadata[TurnKey.agent] != agentStatus { row.metadata[TurnKey.agent] = agentStatus }
            switch event {
            case .token, .replace:
                if case .replace = event, !earlierParts.isEmpty, row.content.isEmpty,
                   row.metadata[TurnReplyText.separator] == nil, addition.hasPrefix("\n\n") {
                    row.metadata[TurnReplyText.separator] = "\n\n"
                    addition.removeFirst(2)
                }
                if !addition.isEmpty { row.content += addition }
                if cumulativeReplacements, let previous = earlierParts.last {
                    TurnReplyText.keepProseTogether(previous, row)
                }
                row.lastTextAt = row.content.isEmpty ? nil : now()
                objectWillChange.send(); autosaveIfDue()
            case .status(let value) where value == TurnErrorCopy.reconnecting: row.metadata[TurnKey.reconnecting] = "1"; objectWillChange.send()
            case .status(let value) where HerdrTurnStatus(code: value) != nil:
                agentStatus = value; row.metadata[TurnKey.agent] = value
                // An agent that waits in its terminal is raised to the person, with what it asks.
                herdrTurnStatus(HerdrTurnStatus(code: value), for: bot, in: group)
                // Live guidance must target the user's active runtime turn.
                if let slot = runningTurns.values.first(where: { $0.assistant === row }) {
                    await steerFollowsBackend(slot, bot: bot, status: HerdrTurnStatus(code: value))
                }
                objectWillChange.send()
            case .status(let value): if row.content.isEmpty { row.metadata["status"] = value }
            case .tool(let tool):
                if tool.name == "_thinking", tool.phase == .progress { row.lastTextAt = nil }
                let owner: ChatMessage
                if tool.phase != .started, let part = earlierParts.first(where: { part in
                    part.activity?.steps.contains { $0.isRunning && (tool.callID == nil ? $0.name == tool.name : $0.callID == tool.callID) } == true
                }) {
                    owner = part
                } else { owner = row }
                if owner === row, row.content.isEmpty, ToolActivity.isShown(tool.name) { row.metadata["status"] = tool.name }
                var activity = owner.activity ?? ToolActivity()
                activity.apply(tool, at: now(), textOffset: owner.content.utf16.count)
                if owner !== row, activity.current == nil { activity.finish(at: now()) }
                if activity.total > 0 { owner.activity = activity; objectWillChange.send() }
            case .accepted(let receipt):
                if assistant.metadata[GoalKey.attempt] == nil {
                    assistant.deliveryReceipt = receipt
                    save()
                }
            case .journal(let server, let ids): finalJournal = ids.map { "\(server):\($0)" }.joined(separator: " ")
            case .sessionModel(let name, let source):
                // A slower launch-profile read may finish after the reply with turn-specific evidence.
                if source.describesReply || sessionModel?.source.describesReply != true { sessionModel = (name, source) }
            case .published(let server, let result):
                var saved = row.publishedResults ?? HerdrReplyResults(serverID: server, items: [])
                if !saved.items.contains(where: { $0.id == result.id }) {
                    saved.items.append(result)
                    row.publishedResults = saved
                    autosaveIfDue()
                }
            case .runActivity(let seconds, let tools): activitySummary = (seconds, tools)
            case .completed:
                if let finalJournal { assistant.metadata["herdrJournal"] = finalJournal }
                completed = true
            case .failed(let value): failure = value
            }
            if continued { objectWillChange.send(); save() }
        }
        if Task.isCancelled { throw CancellationError() }
        if let failure { return .failedByAgent(failure) }
        if completed {
            if let activitySummary {
                row.runSummary = RunSummary(model: sessionModel?.name, modelSource: sessionModel?.source, seconds: activitySummary.seconds, tools: activitySummary.tools)
            }
            return .completed
        }
        return .endedWithoutTerminal
    }

    /// The one place that decides what the end of a turn means: stamps the row, writes a persisted warning line for every
    /// failure and sets `errorMessage`. Never deletes a row.
    @discardableResult func finishTurn(_ end: TurnEnd, assistant: ChatMessage, bot: Bot, in conversation: any Conversation,
                                       alertPrefix: String = "", warn: Bool = true, alert: Bool = true) -> TurnOutcome {
        assistant.isStreaming = false
        // The live "first tool" status ends with the turn.
        assistant.metadata["status"] = nil; assistant.metadata[TurnKey.reconnecting] = nil; assistant.metadata[TurnKey.agent] = nil
        herdrTurnStatus(nil, for: bot, in: conversation as? GroupChat)
        if var activity = assistant.activity { activity.finish(at: now()); assistant.activity = activity }
        if assistant.turnState == .stopped { return TurnOutcome.classify(.stoppedByUser) }
        let outcome = TurnOutcome.classify(end)
        if outcome.state != .incomplete || outcome.why == "error" { assistant.deliveryReceipt = nil }
        assistant.turnState = outcome.state
        assistant.metadata[TurnKey.why] = outcome.state == .finished ? nil : outcome.why
        assistant.metadata[TurnKey.ambiguous] = outcome.ambiguous ? "1" : nil
        switch end {
        case .error(HerdrClient.Failure.signInRequired(let agent, let program)):
            showSignIn(for: bot, in: conversation as? GroupChat, agent: agent, program: program)
        case .failedByAgent(let text) where alert: presentError(alertPrefix + text, reason: .agent, bot: bot)
        // A dropped or timed-out connection is the row's footer and warning line, never the alert.
        case .error(let error) where alert && !TransientNetwork.isTransient(error): presentError(alertPrefix + error.localizedDescription, reason: .send, bot: bot)
        default: break
        }
        if warn, let reason = outcome.reason {
            var text = reason
            if case .error(let error) = end { text = error.localizedDescription }
            addWarning("\(bot.name): \(text)", in: conversation, after: assistant)
        }
        if case .stopsRest = outcome.round { turns.failureStreak += 1 } else if outcome.state == .finished { noteTurnSuccess() }
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

    /// The turn behind `send(text:)` and Retry: the stream, `finishTurn`, release. A turn that never left the Mac
    /// (offline, server unreachable) is sent again by itself: "Reconnecting…".
    func runChatTurn(bot: Bot, conversation: any Conversation, assistant: ChatMessage, history: [(role: String, content: String)], images: [String],
                     systemPrompt: String, backend activeBackend: any AgentBackend, token: UUID, files: [HerdrClient.TaskFile] = []) async {
        guard let slot = turn(token: token) else { return }
        let sendServerID = herdrServer(for: bot).id
        var end: TurnEnd
        var sendFailures = 0
        while true {
            if let attempt = slot.goalAttempt {
                guard !slot.stopping, !Task.isCancelled else { end = .stoppedByUser; break }
                do {
                    if let reason = try await activeBackend.goalBlocker(sessionID: turnSessionID(in: bot, bot: bot)) {
                        end = .error(BackendError.unavailable(reason))
                        break
                    }
                } catch {
                    // Even a transient preflight failure gives the decision back to the person.
                    end = .error(error)
                    break
                }
                guard isCurrent(token), !slot.stopping, !Task.isCancelled,
                      bot.goal?.attempt == attempt, goalDestinationMatches(bot) else {
                    end = .stoppedByUser
                    break
                }
            }
            slot.backend = activeBackend
            end = await HerdrClient.$queueWhenBusy.withValue(conversation === bot && slot.goalAttempt == nil) {
                await streamChatTurn(bot: bot, conversation: conversation, assistant: assistant, history: history, images: images,
                                     systemPrompt: systemPrompt, backend: activeBackend, token: token, files: files)
            }
            if Task.isCancelled { end = .stoppedByUser }
            guard let delay = sendRetryDelay(after: end, failures: sendFailures), isCurrent(token) else { break }
            if slot.goalAttempt != nil { slot.backend = nil }
            sendFailures += 1
            resetForResend(assistant, status: TurnErrorCopy.reconnecting)
            do { try await sendRetrySleep(delay) } catch { end = .stoppedByUser; break }
            if Task.isCancelled { end = .stoppedByUser; break }
        }
        setSteerAvailable(false, token: token)
        let assistant = endTurnParts(assistant, end: end)
        // Acknowledgement can cross the final stream event. Keep the next goal
        // iteration from taking an older snapshot of the objective.
        for receipt in Array(slot.guidanceReceipts.values) { await receipt.value }
        let cancelled: Bool; if case .stoppedByUser = end { cancelled = true } else { cancelled = false }
        if cancelled, assistant.turnState != .stopped { assistant.turnState = .stopped }
        if conversation === bot, isCurrent(token), let attempt = slot.goalAttempt,
           let goal = bot.goal, goal.stepSpending?.attempt == attempt {
            await recordGoalStepCost(in: bot, goalID: goal.id, iteration: goal.iteration)
        }
        let waitReason: String?
        switch end {
        case .error(HerdrClient.Failure.waitingAtPrompt), .error(HerdrClient.Failure.signInRequired): waitReason = TurnWaitCopy.atPrompt
        case .error(is HerdrClient.BusySession): waitReason = TurnWaitCopy.busy
        default: waitReason = nil
        }
        if let waitReason, isCurrent(token),
           !slot.stopping, conversation === bot, slot.goalAttempt == nil,
           let userID = assistant.metadata[TurnKey.forUser], let user = bot.messages.first(where: { $0.id.uuidString == userID }),
           assistant.content.isEmpty, assistant.deliveryReceipt == nil,
           let assistantIndex = bot.messages.firstIndex(where: { $0 === assistant }) {
            bot.messages.remove(at: assistantIndex)
            if case .error(let busy as HerdrClient.BusySession) = end {
                user.metadata[TurnWaitCopy.busyCore] = busy.core
                user.metadata[TurnWaitCopy.busyAddress] = busy.ref.address
                user.metadata[TurnWaitCopy.busyCreated] = String(busy.ref.createdMs)
            }
            user.metadata[TurnWaitCopy.promptServer] = sendServerID
            // This request already reached dispatch. Requeue it ahead of its followers without linking it to itself.
            let predecessor: QueuePredecessor = tracksPredecessor(of: user, in: bot) ? .independent : .conversation
            if waitForTurn(user, in: bot, reason: waitReason, predecessor: predecessor, keepOnFailure: true) {
                endTurn(token)
                if case .error(HerdrClient.Failure.signInRequired(let agent, let program)) = end {
                    showSignIn(for: bot, in: nil, agent: agent, program: program)
                }
                sendQueuedNextMessage()
                return
            }
            TurnWaitCopy.clearDestination(of: user)
            bot.messages.insert(assistant, at: min(assistantIndex, bot.messages.count))
        }
        let waitingForPerson = slot.goalAttempt != nil && herdrWaits(bot).waits
        let outcome = finishTurn(end, assistant: assistant, bot: bot, in: conversation)
        if conversation === bot, isCurrent(token), let attempt = slot.goalAttempt {
            settleGoalTurn(in: bot, attempt: attempt, row: assistant, outcome: outcome, waitingForPerson: waitingForPerson)
        }
        endTurn(token)
        if outcome.state == .finished { directReplyArrived(assistant, from: bot) }
        if launchWorkEnabled, conversation === bot, outcome.state == .incomplete {
            recoverAcceptedReply(in: bot, row: assistant)
        }
        save()
        sendQueuedNextMessage()
        // The main bot's decided bots are created, and requests for bots are passed between bots.
        if conversation === bot { herdrReplyEnded(assistant, from: bot, finished: outcome.state == .finished) }
    }

    /// Live and recovered direct replies share the same unread and notification rules.
    func directReplyArrived(_ reply: ChatMessage, from bot: Bot) {
        guard !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !SilentReply.isSilent(SwarmhubBlock.visibleText(reply.finalText)) else { return }
        if !showsDirectChat(bot) { bot.unreadCount += 1 }
        AvatarReactions.shared.completed(bot)
        notifyIfNeeded(bot: bot, message: displayLine(reply))
    }

    /// One attempt of a turn: the stream, and how it ended.
    private func streamChatTurn(bot: Bot, conversation: any Conversation, assistant: ChatMessage, history: [(role: String, content: String)], images: [String],
                                systemPrompt: String, backend activeBackend: any AgentBackend, token: UUID, files: [HerdrClient.TaskFile]) async -> TurnEnd {
        var end: TurnEnd
        do {
            let stream = try await activeBackend.send(.init(sessionID: turnSessionID(in: conversation, bot: bot), systemPrompt: systemPrompt, messages: history, images: images, files: files))
            if !(activeBackend is HerdrBackend), isCurrent(token) {
                let flags = try? await activeBackend.features()
                setSteerAvailable(flags?.contains("run_steer") == true, token: token)
            }
            end = try await consumeTurn(stream, assistant: assistant, bot: bot, cumulativeReplacements: activeBackend is HerdrBackend)
        } catch is CancellationError { end = .stoppedByUser
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled { end = .stoppedByUser
        } catch { end = .error(error) }
        return end
    }

    /// The session a turn names to its backend: the chat's own when it has one, else the bot's id.
    func turnSessionID(in conversation: any Conversation, bot: Bot) -> String {
        if let group = conversation as? GroupChat, bot.backend == .herdr {
            return sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id)
        }
        if let group = conversation as? GroupChat { return group.session(for: bot.id) ?? sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id) }
        return conversation.sessionID ?? bot.id.uuidString
    }

    /// How long to wait before a turn that provably never started is sent again; nil when it is not sent again.
    func sendRetryDelay(after end: TurnEnd, failures: Int) -> Duration? {
        guard failures < sendRetryDelays.count, case .error(let error) = end, Self.isTransient(error) else { return nil }
        return sendRetryDelays[failures]
    }

    /// Only failures that prove the server did not start the turn: a timeout or a dropped stream may have.
    static func isTransient(_ error: Error) -> Bool {
        if let broken = error as? StreamBreak { return !broken.delivered && (broken.requestStarted == false || isTransient(broken.underlying)) }
        if let url = error as? URLError { return TurnOutcome.certainlyUnsentCodes.contains(url.code) }
        if case BackendError.http(let code, _) = error { return [429, 503].contains(code) }
        // The proxy in front of the network was unreachable, so nothing reached the server.
        let ns = error as NSError
        guard ns.domain == TransientNetwork.cfNetworkDomain else { return false }
        return TransientNetwork.cfProxyCodes.contains(ns.code) || TurnOutcome.certainlyUnsentCodes.contains(URLError.Code(rawValue: ns.code))
    }

    /// The reply row as it was before anything arrived, with `status` under it.
    func resetForResend(_ assistant: ChatMessage, status: String) {
        assistant.content = ""; assistant.activity = nil; assistant.publishedResults = nil; assistant.lastTextAt = nil
        assistant.turnState = .incomplete; assistant.isStreaming = true
        [TurnKey.why, TurnKey.ambiguous, TurnKey.agent].forEach { assistant.metadata[$0] = nil }
        assistant.metadata["status"] = status
        assistant.metadata[TurnKey.reconnecting] = status == TurnErrorCopy.reconnecting ? "1" : nil
        objectWillChange.send()
    }

    /// History for a turn: the transcript up to and including `last`, without steer bubbles, warning lines, app-only lines and empty replies.
    func chatHistory(_ conversation: any Conversation, upTo last: ChatMessage? = nil, excluding reply: ChatMessage, inlineFiles: Bool = true) -> [(role: String, content: String)] {
        var rows = (conversation as? Bot).map { readableMessages(conversation.messages, for: $0.id) } ?? conversation.messages
        if let last, let index = rows.firstIndex(where: { $0.id == last.id }) { rows = Array(rows[...index]) }
        return rows.filter { $0.id != reply.id && !$0.isSteer && $0.metadata[TurnKey.tone] != "warning" && !AppOnlyLine.isAppOnly($0, knownBotNames: bots.map(\.name)) && !($0.role == .assistant && $0.turnState != nil && $0.content.isEmpty) }
            .map { (role: $0.role.rawValue, content: inlineFiles || $0.id != last?.id ? $0.outgoingText : ($0.isCorrection ? SteerCopy.lead + "\n" + $0.modelText : $0.modelText)) }
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

    func noteTurnSuccess() {
        clearConnectionNotice()
        turns.failureStreak = 0
    }
}
