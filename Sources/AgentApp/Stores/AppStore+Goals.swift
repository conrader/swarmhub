import Foundation

/// P45 2: `/goal <text>` — a standing goal on one chat. SwarmHub sends the goal with its protocol as the first turn, then
/// "Continue toward the goal" after each finished reply until the bot ends it with a goal block (done or blocked), the
/// user pauses, clears or stops it, a turn fails, or the budget (Settings → Chats) is used up.
extension AppStore {
    var goalBudget: (rounds: Int, hours: Double) {
        let rounds = defaults.integer(forKey: GoalProtocol.roundsKey), hours = defaults.double(forKey: GoalProtocol.hoursKey)
        return (rounds > 0 ? rounds : GoalProtocol.defaultRounds, hours > 0 ? hours : GoalProtocol.defaultHours)
    }

    func goal(in conversation: any Conversation) -> GoalRun? { automations[conversation.id]?.goal }

    func updateGoal(in conversation: any Conversation, _ change: (inout GoalRun) -> Void) {
        guard var goal = automations[conversation.id]?.goal else { return }
        change(&goal); automations[conversation.id, default: .init()].goal = goal; save()
    }

    // MARK: Commands

    func goalCommand(_ arguments: String, bot: Bot, conversation: any Conversation) {
        let word = arguments.lowercased()
        switch word {
        case "": commandLine(goal(in: conversation).map(goalStatus) ?? "No goal in this chat. Type /goal <what you want done>.", in: conversation)
        case "status": commandLine(goal(in: conversation).map(goalStatus) ?? "No goal in this chat.", in: conversation)
        case "pause":
            guard goal(in: conversation)?.state == .running else { commandLine("No running goal to pause.", in: conversation); return }
            updateGoal(in: conversation) { $0.state = .paused; $0.pausedOffline = false }
            commandLine("Goal paused. The current reply finishes; nothing more is sent until /goal resume.", in: conversation)
        case "resume": resumeGoal(bot: bot, conversation: conversation)
        case "takeover" where automations[conversation.id]?.boxHandoff?.kind == .goal: takeOverHandoff(in: conversation)
        case "clear":
            guard goal(in: conversation) != nil else { commandLine("No goal in this chat.", in: conversation); return }
            automations[conversation.id]?.goal = nil; pruneAutomations(conversation)
            commandLine("Goal cleared.", in: conversation)
        default: startGoal(arguments, bot: bot, conversation: conversation)
        }
    }

    func subgoalCommand(_ arguments: String, conversation: any Conversation) {
        guard let goal = goal(in: conversation), goal.isActive else { commandLine("Subgoals need a running goal: /goal <text> first.", in: conversation); return }
        let parts = arguments.split(separator: " ", maxSplits: 1).map(String.init)
        if arguments.lowercased() == "clear" {
            updateGoal(in: conversation) { $0.subgoals = [] }; commandLine("Subgoals cleared.", in: conversation)
        } else if parts.first?.lowercased() == "remove", let number = parts.dropFirst().first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            guard goal.subgoals.indices.contains(number - 1) else { commandLine("No subgoal \(number); there are \(goal.subgoals.count).", in: conversation); return }
            updateGoal(in: conversation) { $0.subgoals.remove(at: number - 1) }; commandLine("Subgoal \(number) removed.", in: conversation)
        } else if arguments.isEmpty {
            commandLine(goal.subgoals.isEmpty ? "No subgoals. Type /subgoal <criterion>." : goal.subgoals.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"), in: conversation)
        } else {
            updateGoal(in: conversation) { $0.subgoals.append(arguments) }
            commandLine("Subgoal \(goal.subgoals.count + 1) added; the next round includes it.", in: conversation)
        }
    }

    func startGoal(_ text: String, bot: Bot, conversation: any Conversation) {
        if let existing = goal(in: conversation), existing.isActive {
            commandLine("This chat already has a goal: \(existing.text). Type /goal clear first.", in: conversation); return
        }
        let budget = goalBudget
        // `--coding` requires commit/test evidence, `--general` accepts the chat deliverable; a plain goal is judged by
        // its text (`GoalRun.requiresCodingEvidence`).
        let coding = text.hasPrefix("--coding "), general = text.hasPrefix("--general ")
        let goalText = coding ? String(text.dropFirst(9)) : general ? String(text.dropFirst(10)) : text
        let evidence: Bool? = coding ? true : general ? false : nil
        let goal = GoalRun(text: goalText, maxRounds: budget.rounds, startedAt: now(), maxDuration: budget.hours * 3600, codingEvidence: evidence)
        automations[conversation.id, default: .init()].goal = goal
        save(); startAutomationTicker()
        commandLine("Goal: \(goal.text)\n\(goal.evidenceStatus)", in: conversation)
        advanceGoal(in: conversation, bot: bot)
    }

    func resumeGoal(bot: Bot, conversation: any Conversation) {
        guard let goal = goal(in: conversation), goal.state == .paused || goal.state == .blocked else { commandLine("No paused or blocked goal to resume.", in: conversation); return }
        updateGoal(in: conversation) { $0.state = .running; $0.pausedOffline = false; $0.need = nil; $0.evidenceRounds = 0 }
        advanceGoal(in: conversation, bot: bot)
    }

    func goalStatus(_ goal: GoalRun) -> String {
        let minutes = Int(now().timeIntervalSince(goal.startedAt) / 60)
        var lines = ["Goal: \(goal.text)", "\(goal.state.rawValue.capitalized)\(goal.pausedOffline ? " (offline)" : "") · \(goal.progress) · \(minutes) min of \(Int(goal.maxDuration / 60))"]
        lines.append(goal.evidenceStatus)
        lines += goal.subgoals.enumerated().map { "  \($0.offset + 1). \($0.element)" }
        if let need = goal.need { lines.append("Needs: \(need)") }
        if let summary = goal.lastSummary { lines.append("Last: \(summary)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Driver

    /// Sends the next round when the goal runs, the chat is free and online, and the budget allows.
    func advanceGoal(in conversation: any Conversation, bot: Bot) {
        guard let goal = goal(in: conversation), goal.state == .running, !goal.awaitingReply, isIdle(conversation), !hasWaitingTurn(in: conversation),
              automations[conversation.id]?.boxHandoff?.kind != .goal else { return }
        if turns.pathDown { updateGoal(in: conversation) { $0.state = .paused; $0.pausedOffline = true }; return }
        if goal.budgetSpent(at: now()) {
            let why = goal.round >= goal.maxRounds ? "all \(goal.maxRounds) rounds used" : "the \(Self.hours(goal.maxDuration)) limit reached"
            endGoal(in: conversation, card: "goalEnded", title: "Goal stopped: \(why)", detail: goal.lastSummary); return
        }
        let first = goal.round == 0
        let text = first ? GoalProtocol.firstTurn(goal) : GoalProtocol.continuation(goal)
        var metadata = [AutomationKey.display: first ? "Goal: \(goal.text)" : "Continue toward the goal"]
        if !first { metadata[AutomationKey.woken] = AutomationKind.goal.rawValue }
        guard send(text: text, bot: bot, conversation: conversation, replyToID: nil, waitWhenFull: true, metadata: metadata) else {
            endGoal(in: conversation, card: "goalEnded", title: "Goal stopped: the round could not be sent", detail: errorMessage); return
        }
        updateGoal(in: conversation) { $0.round += 1; $0.awaitingReply = true }
    }

    /// The end of any turn in a chat with a goal: a goal block ends it; Stop or a failed turn ends it; otherwise the next round.
    func goalTurnEnded(in conversation: any Conversation, bot: Bot, reply: ChatMessage, outcome: TurnOutcome) {
        guard let goal = goal(in: conversation), goal.isActive else { return }
        updateGoal(in: conversation) { $0.awaitingReply = false }
        switch outcome.state {
        case .stopped: endGoal(in: conversation, card: "goalEnded", title: "Goal stopped", detail: "Stopped by you after \(goal.progress)."); return
        case .incomplete, .notSent: endGoal(in: conversation, card: "goalEnded", title: "Goal stopped: the last turn failed", detail: outcome.reason); return
        case .finished: break
        }
        switch GoalProtocol.report(in: reply.finalText) {
        case .done(let summary, let evidence):
            guard goal.accepts(evidence, reply: reply.finalText) else { requestGoalEvidence(in: conversation, bot: bot, goal: goal, summary: summary, evidence: evidence); return }
            updateGoal(in: conversation) { $0.lastSummary = summary }
            endGoal(in: conversation, state: .done, card: "goalDone", title: "Goal reached", detail: (summary.isEmpty ? goal.text : summary) + "\n" + goal.doneDetail(evidence))
        case .blocked(let need):
            updateGoal(in: conversation) { $0.state = .blocked; $0.need = need }
            addGoalCard(in: conversation, card: "goalBlocked", title: "Goal blocked", detail: need.isEmpty ? "The bot needs something from you." : need)
        case nil:
            let visible = SwarmhubBlock.visibleText(reply.finalText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !visible.isEmpty { updateGoal(in: conversation) { $0.lastSummary = String(visible.prefix(200)) } }
            advanceGoal(in: conversation, bot: bot)
        }
    }

    /// P01/P04 gap: a `done` without a commit or test pass plus a fresh report is not accepted. The card says what the
    /// bot claimed and what is missing; the bot gets `GoalProtocol.maxEvidenceRounds` rounds to supply evidence (or
    /// report blocked), then the goal is blocked for you. SwarmHub verifies nothing itself and says so.
    func requestGoalEvidence(in conversation: any Conversation, bot: Bot, goal: GoalRun, summary: String, evidence: GoalEvidence) {
        let spent = (goal.evidenceRounds ?? 0) + 1
        updateGoal(in: conversation) { $0.evidenceRounds = spent; if !summary.isEmpty { $0.lastSummary = summary } }
        addGoalCard(in: conversation, card: "goalUnverified", title: "Done claimed without evidence", detail: goal.requiresCodingEvidence ? evidence.summary : "The requested deliverable is missing.")
        guard goal.state == .running else { return } // Pause still wins when the last reply claims done.
        guard !goal.budgetSpent(at: now()) else {
            endGoal(in: conversation, card: "goalEnded", title: "Goal stopped: evidence missing at the budget limit", detail: goal.requiresCodingEvidence ? evidence.summary : "The requested deliverable is missing.")
            return
        }
        if turns.pathDown { updateGoal(in: conversation) { $0.state = .paused; $0.pausedOffline = true }; return }
        guard spent <= GoalProtocol.maxEvidenceRounds else {
            updateGoal(in: conversation) { $0.state = .blocked; $0.need = goal.requiresCodingEvidence ? "evidence for done: a commit id or a test pass, plus the fresh report path" : "the requested deliverable" }
            addGoalCard(in: conversation, card: "goalBlocked", title: "Goal blocked",
                        detail: "The bot said done \(spent) times without evidence. Check its work yourself, or resume to ask again.")
            return
        }
        let metadata = [AutomationKey.display: "Evidence for done", AutomationKey.woken: AutomationKind.goal.rawValue]
        guard send(text: GoalProtocol.evidenceRequest(goal, evidence: evidence), bot: bot, conversation: conversation, replyToID: nil, waitWhenFull: true, metadata: metadata) else {
            endGoal(in: conversation, card: "goalEnded", title: "Goal stopped: the evidence request could not be sent", detail: errorMessage); return
        }
        updateGoal(in: conversation) { $0.round += 1; $0.awaitingReply = true }
    }

    func endGoal(in conversation: any Conversation, state: GoalRun.State = .ended, card: String, title: String, detail: String?) {
        updateGoal(in: conversation) { $0.state = state; $0.awaitingReply = false; $0.endReason = title }
        addGoalCard(in: conversation, card: card, title: title, detail: detail)
    }

    private func addGoalCard(in conversation: any Conversation, card: String, title: String, detail: String?) {
        var metadata = [AutomationKey.card: card]
        metadata[AutomationKey.detail] = detail.flatMap { $0.isEmpty ? nil : $0 }
        conversation.messages.append(ChatMessage(role: .system, content: title, presentation: .automation, metadata: metadata))
        objectWillChange.send(); save()
    }

    static func hours(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        return hours == hours.rounded() ? "\(Int(hours)) h" : "\(Int(seconds / 60)) min"
    }
}
