import CoreFoundation
import Foundation

/// Group rounds can reuse a slot for successive replies, and retry can reuse a row in a new slot.
struct StartupSteerTarget: Equatable {
    let turn: UUID
    let reply: UUID
}

/// The running turn of one conversation (a bot's chat or a group). Chats never share a slot, so a long reply blocks
/// only its own chat.
@MainActor final class ConversationTurn {
    let token = UUID()
    let conversation: any Conversation
    var task: Task<Void, Never>?
    var backend: (any AgentBackend)?
    /// The bot answering now (a group round moves it from member to member) and the row it streams into.
    var botID: UUID?; var assistant: ChatMessage?
    /// The running turn takes steer messages (`run_steer`).
    var steerAvailable = false
    var awaitingSteerCapability = false
    var startupTarget: StartupSteerTarget? { assistant.map { StartupSteerTarget(turn: token, reply: $0.id) } }
    var lastSteerDelivery: Task<Void, Never>?
    var groupRun: GroupRun?
    var stopping = false
    var goalAttempt: UUID?
    var guidanceReceipts: [UUID: Task<Void, Never>] = [:]
    // The workspace interrupt targets an agent session. Keep its slot until both
    // the local stream and the remote stop request have settled.
    var goalStopPending = false
    var endedDuringGoalStop = false
    init(conversation: any Conversation, botID: UUID?, assistant: ChatMessage?, groupRun: GroupRun?) {
        self.conversation = conversation; self.botID = botID; self.assistant = assistant; self.groupRun = groupRun
    }
}

/// How many turns may run at once, app-wide and per server (`connection(of:)`).
struct TurnLimits: Equatable, Sendable {
    static let range = 1...32
    private static let totalKey = "turnLimits.total"
    private static let perConnectionKey = "turnLimits.perConnection"

    var total: Int
    var perConnection: Int

    init(total: Int = 6, perConnection: Int = 4) {
        self.perConnection = Self.clamp(perConnection)
        self.total = max(Self.clamp(total), self.perConnection)
    }

    init(defaults: UserDefaults) {
        let fallback = Self()
        self.init(total: Self.integer(forKey: Self.totalKey, in: defaults) ?? fallback.total,
                  perConnection: Self.integer(forKey: Self.perConnectionKey, in: defaults) ?? fallback.perConnection)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(total, forKey: Self.totalKey)
        defaults.set(perConnection, forKey: Self.perConnectionKey)
    }

    private static func clamp(_ limit: Int) -> Int {
        min(max(limit, range.lowerBound), range.upperBound)
    }

    private static func integer(forKey key: String, in defaults: UserDefaults) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }
}

extension AppStore {
    // MARK: Slots

    func turn(in conversation: any Conversation) -> ConversationTurn? {
        runningTurns[conversation.id].flatMap { $0.conversation === conversation ? $0 : nil }
            ?? runningTurns.values.first { $0.conversation === conversation }
    }
    func turn(token: UUID) -> ConversationTurn? { runningTurns.values.first { $0.token == token } }
    func isCurrent(_ token: UUID) -> Bool { turn(token: token) != nil }
    /// The chat's turn streams and was not stopped (its composer shows Stop). A stopped turn holds the slot until its task ends.
    func isStreaming(in conversation: any Conversation) -> Bool { turn(in: conversation).map { !$0.stopping } ?? false }
    /// No turn holds the chat's slot: a new one may start there.
    func isIdle(_ conversation: any Conversation) -> Bool { turn(in: conversation) == nil }
    /// App-wide only: something answers somewhere (Stop menu fallback, headless waits).
    var anyTurnRunning: Bool { !runningTurns.isEmpty }
    /// The chat the window shows: the open group, else the selected bot's chat.
    var openConversation: (any Conversation)? { showOnlyAttention ? nil : selectedGroup ?? selectedBot }
    func canSteer(in conversation: any Conversation) -> Bool { turn(in: conversation)?.steerAvailable == true }

    /// Claims `conversation`'s slot; the caller checked it was free.
    @discardableResult func beginTurn(in conversation: any Conversation, bot: Bot?, assistant: ChatMessage?, groupRun: GroupRun? = nil) -> ConversationTurn {
        let turn = ConversationTurn(conversation: conversation, botID: bot?.id, assistant: assistant, groupRun: groupRun)
        runningTurns[conversation.id] = turn
        return turn
    }

    /// Frees the slot `token` holds (a no-op once Stop or another end released it).
    func endTurn(_ token: UUID) {
        guard let turn = turn(token: token) else { return }
        if turn.goalStopPending {
            turn.endedDuringGoalStop = true
            return
        }
        if let key = runningTurns.first(where: { $0.value === turn })?.key { runningTurns[key] = nil }
    }

    /// Sets the running turn's steer flag (the composer of that chat reads it).
    func setSteerAvailable(_ value: Bool, token: UUID) {
        guard let turn = turn(token: token), turn.steerAvailable != value else { return }
        turn.steerAvailable = value; objectWillChange.send()
    }

    /// The chat (a bot's or a group) that holds the row.
    func conversation(containing rowID: UUID) -> (any Conversation)? {
        if let bot = bots.first(where: { $0.messages.contains { $0.id == rowID } }) { return bot }
        return groups.first { $0.messages.contains { $0.id == rowID } }
    }

    // MARK: Limits

    func setPerConnectionTurnLimit(_ limit: Int) {
        updateTurnLimits(TurnLimits(total: turnLimits.total, perConnection: limit))
    }

    func setTotalTurnLimit(_ limit: Int) {
        updateTurnLimits(TurnLimits(total: limit, perConnection: min(limit, turnLimits.perConnection)))
    }

    private func updateTurnLimits(_ limits: TurnLimits) {
        objectWillChange.send()
        turnLimits = limits
        limits.save(to: defaults)
        sendQueuedNextMessage()
    }

    /// What a bot's turns count against: its Herdr server; a sample agent runs here.
    func connection(of bot: Bot) -> String { bot.backend == .herdr ? "herdr:\(herdrServer(for: bot).id)" : "local" }

    /// Why a new turn for `bots` must wait (nil when it may start): the app-wide limit, then each bot's connection.
    func turnCapacityProblem(for bots: [Bot]) -> String? {
        if bots.contains(where: { herdrMovingWork.contains($0.id) }) { return "Waiting for the server move to finish." }
        if runningTurns.count >= turnLimits.total { return turnWaitMessage(limit: turnLimits.total) }
        let running = runningTurns.values.compactMap { turn in turn.botID.flatMap { id in self.bots.first { $0.id == id } }.map(connection(of:)) }
        for target in Set(bots.map(connection(of:))) where running.filter({ $0 == target }).count >= turnLimits.perConnection {
            return turnWaitMessage(limit: turnLimits.perConnection, onServer: true)
        }
        return nil
    }

    private func turnWaitMessage(limit: Int, onServer: Bool = false) -> String {
        let replies = limit == 1 ? "1 reply is" : "\(limit) replies are"
        let location = onServer ? " on this server" : ""
        return "Waiting: \(replies) already running\(location)."
    }

    // MARK: Stop

    /// Stop in the open chat (the composer's Stop and ⌘.): only that chat's turn.
    func stop() { if let conversation = openConversation { stop(conversation) } }

    func stop(_ conversation: any Conversation) {
        for turn in runningTurns.values.filter({ $0.conversation === conversation && !$0.stopping }) { stop(turn) }
    }

    private func stop(_ turn: ConversationTurn) {
        let conversation = turn.conversation
        // The slot stays until the turn's task ends (`endTurn`), as the one app-wide slot did before P39.
        let bufferID = conversation is GroupChat ? steerOrigin(turn) : conversation.id
        if let bufferID { turns.textBuffers[bufferID]?.flush() }
        turn.stopping = true; turn.groupRun?.stopped = true
        let streamToken = turn.token
        let bot = turn.botID.flatMap { id in bots.first { $0.id == id } }
        turn.assistant?.isStreaming = false; turn.steerAvailable = false
        herdrStopWaitingExchanges(in: conversation)
        // The row is `stopped` at once and never extended.
        if let row = turn.assistant, row.turnState != .notSent { row.turnState = .stopped; row.metadata[TurnKey.why] = "stopped" }
        objectWillChange.send()
        if let attempt = turn.goalAttempt {
            if let bot, let goal = bot.goal, goal.attempt == attempt {
                turns.scheduledGoals.remove(goal.id)
                bot.goal?.stop()
                save()
            }
            // A goal still checking approvals has no delivery to interrupt.
            if turn.backend == nil {
                if let task = turn.task { task.cancel() } else { endTurn(streamToken) }
                return
            }
        }
        guard let bot, let activeBackend = turn.backend ?? (try? backend(for: bot)) else {
            // The task's end frees the slot; a slot without a task is freed here.
            if let task = turn.task { task.cancel() } else { endTurn(streamToken) }
            return
        }
        let taskToCancel = turn.task
        let stoppedAssistant = turn.assistant
        if bot.backend == .herdr, let row = stoppedAssistant, row.turnState == .stopped {
            row.metadata[TurnKey.why] = TurnKey.stopPending
            save()
        }
        let sessionID = turn.goalAttempt.flatMap { _ in bot.goal?.destination.sessionID } ?? turnSessionID(in: conversation, bot: bot)
        turn.goalStopPending = turn.goalAttempt != nil
        let server = bot.backend.shortName
        if conversation is GroupChat, let herdr = activeBackend as? HerdrBackend {
            // Stop an upcoming send as well as one already preparing its request.
            taskToCancel?.cancel()
            herdr.cancelGroupSend(sessionID: sessionID)
        }
        turns.pendingInterrupts[conversation.id, default: []].insert(streamToken)
        Task {
            let feedback: String
            let unconfirmed: Bool
            do {
                // Backends that clear their run on stream termination need the target captured first.
                let target = try await activeBackend.stopTarget(sessionID: sessionID)
                taskToCancel?.cancel()
                didCancelLocalStream?()
                let outcome = try await activeBackend.requestStop(target)
                unconfirmed = outcome == .stillWorking || outcome == .unconfirmed
                switch outcome {
                case .requested: feedback = IntentLine.stopRequested.render(server)
                case .stillWorking: feedback = IntentLine.stillWorking.render(server)
                case .unconfirmed: feedback = IntentLine.stopUnknown.render(server)
                case .noRunControl: feedback = IntentLine.stoppedNoRunControl.render()
                case .noActiveRun: feedback = IntentLine.stoppedBeforeRunID.render(server)
                }
            } catch {
                taskToCancel?.cancel()
                unconfirmed = true
                feedback = IntentLine.stopFailed.render(server, error.localizedDescription)
                let latestReply = conversation.messages.last { $0.role == .assistant }
                let visible = (conversation as? GroupChat).map(showsGroupChat) ?? showsDirectChat(bot)
                let latestStop = stoppedAssistant != nil && latestReply === stoppedAssistant
                if isCurrent(streamToken) || (visible && isIdle(conversation) && latestStop) {
                    presentError(feedback, reason: .stop, bot: bot)
                }
            }
            insertStopLine(feedback, in: conversation, after: stoppedAssistant?.id)
            if let row = stoppedAssistant, row.turnState == .stopped {
                row.metadata[TurnKey.why] = unconfirmed ? TurnKey.stopUnconfirmed : "stopped"
                if !unconfirmed { row.deliveryReceipt = nil }
                else if row.deliveryReceipt != nil {
                    // Wait for the local stream to settle before importing a possible final workspace answer.
                    Task {
                        await taskToCancel?.value
                        recoverAcceptedReply(in: bot, row: row, group: conversation as? GroupChat)
                    }
                }
            }
            turns.pendingInterrupts[conversation.id]?.remove(streamToken)
            if turns.pendingInterrupts[conversation.id]?.isEmpty == true { turns.pendingInterrupts[conversation.id] = nil }
            turn.goalStopPending = false
            if turn.endedDuringGoalStop {
                endTurn(streamToken)
                sendQueuedNextMessage()
            } else { sendQueuedNextMessage() }
            save()
        }
    }

    private func insertStopLine(_ text: String, in conversation: any Conversation, after rowID: UUID?) {
        let message = ChatMessage(role: .system, content: text)
        if let rowID, let index = conversation.messages.firstIndex(where: { $0.id == rowID }) {
            conversation.messages.insert(message, at: index + 1)
        } else { conversation.messages.append(message) }
        objectWillChange.send()
    }
}
