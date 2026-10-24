import Foundation

/// P39: the running turn of one conversation (a bot's main chat, a thread or a group). Chats never share a slot, so a
/// long reply or a manager's install turn blocks only its own chat.
@MainActor final class ConversationTurn {
    let token = UUID()
    let conversation: any Conversation
    var task: Task<Void, Never>?
    /// The bot answering now (a group round moves it from member to member) and the row it streams into.
    var botID: UUID?; var assistant: ChatMessage?
    /// The running turn takes steer messages (`run_steer`).
    var steerAvailable = false
    var groupRun: GroupRun?
    var stopping = false
    init(conversation: any Conversation, botID: UUID?, assistant: ChatMessage?, groupRun: GroupRun?) {
        self.conversation = conversation; self.botID = botID; self.assistant = assistant; self.groupRun = groupRun
    }
}

/// P39 6: how many turns may run at once, app-wide and per connection (`connection(of:)`).
struct TurnLimits: Equatable, Sendable {
    var total = 6, perConnection = 4
}

extension AppStore {
    // MARK: Slots

    func turn(in conversation: any Conversation) -> ConversationTurn? {
        runningTurns[conversation.id].flatMap { $0.conversation === conversation ? $0 : nil }
    }
    func turn(token: UUID) -> ConversationTurn? { runningTurns.values.first { $0.token == token } }
    func isCurrent(_ token: UUID) -> Bool { turn(token: token) != nil }
    /// The chat's turn streams and was not stopped (its composer shows Stop). A stopped turn holds the slot until its task ends.
    func isStreaming(in conversation: any Conversation) -> Bool { turn(in: conversation).map { !$0.stopping } ?? false }
    /// No turn holds the chat's slot: a new one may start there.
    func isIdle(_ conversation: any Conversation) -> Bool { turn(in: conversation) == nil }
    /// App-wide only: something answers somewhere (Stop menu fallback, headless waits).
    var anyTurnRunning: Bool { !runningTurns.isEmpty }
    /// The chat the window shows: the open group, else the selected bot's open thread or main chat.
    var openConversation: (any Conversation)? { selectedGroup ?? selectedBot.map(currentConversation(of:)) }
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
        runningTurns[turn.conversation.id] = nil
    }

    /// Sets the running turn's steer flag (the composer of that chat reads it).
    func setSteerAvailable(_ value: Bool, token: UUID) {
        guard let turn = turn(token: token), turn.steerAvailable != value else { return }
        turn.steerAvailable = value; objectWillChange.send()
    }

    // MARK: Limits

    /// Why a new turn for `bots` must wait (nil when it may start): the app-wide limit, then each bot's connection.
    func turnCapacityProblem(for bots: [Bot]) -> String? {
        if runningTurns.count >= turnLimits.total { return "Waiting: \(turnLimits.total) replies are already running." }
        let running = runningTurns.values.compactMap { turn in turn.botID.flatMap { id in self.bots.first { $0.id == id } }.map(connection(of:)) }
        for target in Set(bots.map(connection(of:))) where running.filter({ $0 == target }).count >= turnLimits.perConnection {
            return "Waiting: \(turnLimits.perConnection) replies are already running on this connection."
        }
        return nil
    }

    // MARK: Stop

    /// Stop in the open chat (the composer's Stop and ⌘.): only that chat's turn.
    func stop() { if let conversation = openConversation { stop(conversation) } }

    func stop(_ conversation: any Conversation) {
        guard let turn = turn(in: conversation), !turn.stopping else { return }
        // The slot stays until the turn's task ends (`endTurn`), as the one app-wide slot did before P39.
        turn.stopping = true; turn.groupRun?.stopped = true
        let streamToken = turn.token
        let bot = turn.botID.flatMap { id in bots.first { $0.id == id } }
        turn.assistant?.isStreaming = false; turn.steerAvailable = false
        // P16: the row is `stopped` at once and never extended; a Retry still reading the box keeps its `notSent` row.
        if let row = turn.assistant, row.turnState != .notSent { row.turnState = .stopped; row.metadata[TurnKey.why] = "stopped" }
        objectWillChange.send()
        guard let bot, let activeBackend = try? backend(for: bot) else {
            // The task's end frees the slot; a slot without a task is freed here.
            if let task = turn.task { task.cancel() } else { endTurn(streamToken) }
            return
        }
        let taskToCancel = turn.task
        let stoppedAssistantID = turn.assistant?.id
        let sessionID = turnSessionID(streamToken, in: conversation, bot: bot)
        let server = bot.backend.shortName // "Hermes" texts stay byte-identical (P12)
        Task {
            do {
                // Capture the run before cancelling the SSE task, whose termination clears it.
                let target = try await activeBackend.stopTarget(sessionID: sessionID)
                taskToCancel?.cancel()
                didCancelLocalStream?()
                let outcome = try await activeBackend.requestStop(target)
                let feedback: String
                switch outcome {
                case .requested: feedback = "Stop requested from \(server)."
                case .disconnectedLegacy: feedback = bot.backend == .openClaw ? "Stopped locally; this OpenClaw Gateway does not offer chat.abort." : "Stopped locally; this Hermes version has no run-control endpoint."
                case .noActiveRun: feedback = "Stopped locally before \(server) supplied a run ID."
                }
                insertStopLine(feedback, in: conversation, after: stoppedAssistantID)
            } catch {
                taskToCancel?.cancel()
                insertStopLine("\(server) Stop failed: \(error.localizedDescription)", in: conversation, after: stoppedAssistantID)
                if isCurrent(streamToken) {
                    errorMessage = "\(server) Stop failed: \(error.localizedDescription)"
                }
            }
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
