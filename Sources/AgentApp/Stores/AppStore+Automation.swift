import Foundation

/// P45 2–5: the hub of what SwarmHub runs in a chat by itself (goal, loop, heartbeat): commands, persistence, the end-of-
/// turn hook and the ticker. Turns it starts are normal turns (approvals, steer and the next-message queue apply).
extension AppStore {
    func automationCommand(_ command: SlashCommand, arguments: String, bot: Bot, conversation: any Conversation) -> Bool {
        switch command {
        case .goal: goalCommand(arguments, bot: bot, conversation: conversation)
        case .subgoal: subgoalCommand(arguments, conversation: conversation)
        case .loop: loopCommand(arguments, bot: bot, conversation: conversation)
        case .heartbeat: heartbeatCommand(arguments, conversation: conversation)
        default: return false
        }
        return true
    }

    /// Stop ends the chat's goal and loop (a heartbeat keeps its schedule: it has its own Stop). True when one was active.
    @discardableResult func stopAutomations(in conversation: any Conversation) -> Bool {
        var stopped = false
        if let goal = goal(in: conversation), goal.isActive {
            endGoal(in: conversation, card: "goalEnded", title: "Goal stopped", detail: "Stopped by you after \(goal.progress)."); stopped = true
        }
        if loop(in: conversation) != nil { endLoop(in: conversation, line: "Loop stopped."); stopped = true }
        return stopped
    }

    func automationStatusLines(for conversation: any Conversation) -> [String] {
        var lines: [String] = []
        if let goal = goal(in: conversation) { lines.append("Goal: \(goal.text) · \(goal.state.rawValue) · \(goal.progress)") }
        if let loop = loop(in: conversation) { lines.append(loopStatus(loop).components(separatedBy: "\n")[0]) }
        if let heartbeat = heartbeat(in: conversation) { lines.append(heartbeatStatus(heartbeat).components(separatedBy: "\n")[0]) }
        return lines
    }

    // MARK: Turn ends

    /// Called by every 1:1 and thread turn when it has ended (after the next-message queue had its chance). A turn stopped
    /// for a typed correction counts as still running: the correction's turn ends it.
    func automationTurnEnded(in conversation: any Conversation, bot: Bot, reply: ChatMessage, outcome: TurnOutcome, corrected: Bool = false) {
        guard automations[conversation.id] != nil, !corrected else { return }
        loopTurnEnded(in: conversation, reply: reply, outcome: outcome)
        heartbeatTurnEnded(in: conversation, reply: reply, outcome: outcome)
        goalTurnEnded(in: conversation, bot: bot, reply: reply, outcome: outcome)
    }

    // MARK: Ticker

    /// One pass over every chat: goals paused offline resume once the connection is back, rounds a restart interrupted are
    /// sent again.
    func automationTick() {
        for (id, automation) in automations {
            guard let (bot, conversation) = automationConversation(id) else { continue }
            if var goal = automation.goal {
                if goal.state == .running, turns.pathDown, !goal.awaitingReply { goal.state = .paused; goal.pausedOffline = true; automations[id]?.goal = goal; save() }
                else if goal.state == .paused, goal.pausedOffline, !turns.pathDown { updateGoal(in: conversation) { $0.state = .running; $0.pausedOffline = false } }
                advanceGoal(in: conversation, bot: bot)
            }
            if automation.loop != nil { runLoopIfDue(in: conversation, bot: bot) }
            if automation.heartbeat != nil { runHeartbeatIfDue(in: conversation, bot: bot) }
        }
    }

    /// Ticks every 15 s while any chat has a goal, loop or heartbeat (only in the real app: tests call `automationTick`).
    func startAutomationTicker() {
        guard botInfo.autoLoad, automationTask == nil, !automations.isEmpty else { return }
        automationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.automations.isEmpty else { break }
                self.automationTick()
                try? await self.automationSleep(.seconds(15))
            }
            self?.automationTask = nil
        }
    }

    // MARK: Persistence

    /// Launch: a round a quit interrupted is no longer awaited (the ticker sends the next one); finished goals stay for status.
    func restoreAutomations(_ stored: [String: ChatAutomation]?) {
        var restored: [UUID: ChatAutomation] = [:]
        for (key, var automation) in stored ?? [:] {
            guard let id = UUID(uuidString: key) else { continue }
            automation.goal?.awaitingReply = false; automation.loop?.awaitingReply = false; automation.heartbeat?.awaitingReply = false
            restored[id] = automation
        }
        automations = restored
    }

    var storedAutomations: [String: ChatAutomation]? {
        let kept = automations.filter { !$0.value.isEmpty }
        return kept.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept.map { ($0.key.uuidString, $0.value) })
    }

    func pruneAutomations(_ conversation: any Conversation) {
        if automations[conversation.id]?.isEmpty == true { automations[conversation.id] = nil }
        save()
    }

    /// The bot chat or thread an automation belongs to (nil once deleted).
    func automationConversation(_ id: UUID) -> (Bot, any Conversation)? {
        for bot in bots where !bot.isReadOnlyArchive {
            if bot.id == id { return (bot, bot) }
            if let thread = bot.threads.first(where: { $0.id == id }) { return (bot, thread) }
        }
        return nil
    }
}
