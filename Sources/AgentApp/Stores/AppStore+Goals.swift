import Foundation

extension AppStore {
    /// The composer passes its own conversation before any steer, queue or attachment delivery.
    func handleGoalCommand(_ command: SlashCommand, in conversation: any Conversation, attachments: [ChatAttachment] = []) -> String? {
        guard openConversation === conversation, openHerdrHelper == nil,
              let bot = conversation as? Bot, bots.contains(where: { $0 === bot }),
              bot.backend == .herdr, !bot.isDemo, !bot.isReadOnlyArchive, persistenceEnabled, storeRestoreOffer == nil
        else { return "Goals require a writable workspace bot chat." }

        switch command {
        case .start(let objective, let stepLimit):
            if bot.goal?.state.active == true {
                guard stepLimit == nil else { return "Stop the current goal before starting one with a new step limit." }
                if let turn = turn(in: bot), !turn.steerAvailable || turn.stopping {
                    return "This goal step cannot take live guidance. Wait for it to finish before updating the goal."
                }
                return send(text: objective, attachments: attachments, bot: bot, conversation: bot, replyToID: replyTo?.id, waitWhenFull: true)
                    ? nil : "The goal update could not be submitted."
            }
            guard attachments.isEmpty else { return "Start the goal, then attach files to a follow-up." }
            var goal = ChatGoal(objective: objective, destination: goalDestination(for: bot), stepLimit: stepLimit)
            // Check the full first delivery while the person still has their draft.
            goal.initialAttachments = attachments.isEmpty ? nil : attachments
            let probe = UUID()
            guard validateHerdrDraft(goal.request(for: probe), attachments: attachments, bot: bot) else { return "The goal could not be sent. Check the message length." }
            let previous = bot.goal
            bot.goal = goal
            save()
            guard !turns.saveFailing else { bot.goal = previous; return "The goal could not be saved." }
            turns.scheduledGoals.insert(goal.id)
            sendQueuedNextMessage()
        case .status:
            guard let goal = bot.goal else { return "This chat has no goal. Type /goal followed by an objective." }
            let state: String
            if let attempt = goal.attempt, turns.nextMessages.contains(where: { $0.conversation === bot && $0.bubble.metadata[GoalKey.attempt] == attempt.uuidString }) { state = "Waiting for capacity" }
            else if goal.state == .running && herdrWaits(bot).waits { state = "Waiting for you" }
            else { state = goal.state.rawValue.capitalized }
            return [state, goal.stepProgress, goal.objective].compactMap { $0 }.joined(separator: " · ")
        case .stop:
            guard let goal = bot.goal, goal.state.active else { return "This chat has no active goal." }
            stopGoal(in: bot)
            if turns.saveFailing { return "The goal stopped in this window, but the stop could not be saved." }
        case .invalidStepLimit: return SlashCommand.stepLimitUsage
        case .commands, .goalUsage:
            return "Use /goal [--steps N] <objective>, /goal status, or /goal stop."
        }
        return nil
    }

    func resumeGoal(in bot: Bot) {
        guard openConversation === bot, bot.goal?.state == .waiting, isIdle(bot),
              goalDestinationMatches(bot), !herdrWaits(bot).waits else { return }
        bot.goal?.resume()
        if let id = bot.goal?.id { turns.scheduledGoals.insert(id) }
        save()
        sendQueuedNextMessage()
    }

    func stopGoal(in bot: Bot) {
        guard let goal = bot.goal, goal.state.active else { return }
        let ownedTurn = goal.attempt != nil && turn(in: bot)?.goalAttempt == goal.attempt
        if let attempt = goal.attempt {
            let pending = turns.nextMessages.filter { $0.conversation === bot && $0.bubble.metadata[GoalKey.attempt] == attempt.uuidString }
            turns.nextMessages.removeAll { next in pending.contains { $0.id == next.id } }
            pending.forEach(giveBack)
        }
        bot.goal?.stop()
        turns.scheduledGoals.remove(goal.id)
        save()
        if ownedTurn { stop(bot) }
    }

    /// Called by the normal queue drain, after messages waiting for a slot had their turn.
    func dispatchQueuedGoals() {
        guard !turns.scheduledGoals.isEmpty, persistenceEnabled, storeRestoreOffer == nil else { return }
        for bot in bots {
            guard var goal = bot.goal, goal.state == .queued, turns.scheduledGoals.contains(goal.id),
                  isIdle(bot), turns.pendingInterrupts[bot.id] == nil, !hasWaitingTurn(in: bot), turnCapacityProblem(for: [bot]) == nil else { continue }
            turns.scheduledGoals.remove(goal.id)
            if goal.stopAtStepLimit() {
                bot.goal = goal
                save()
                continue
            }
            guard goalDestinationMatches(bot) else {
                bot.goal?.wait("The workspace or chat changed. Stop this goal before starting one here.")
                save()
                continue
            }
            guard !herdrWaits(bot).waits, herdrPrompts[bot.id] == nil else {
                bot.goal?.wait("Resolve the workspace prompt, then resume the goal.")
                save()
                continue
            }
            guard pendingHerdrBots(for: bot).isEmpty, pendingHerdrModels(for: bot).isEmpty else {
                bot.goal?.wait("Review the pending request in this chat, then resume the goal.")
                save()
                continue
            }
            let files = goal.initialAttachments ?? []
            let token = goal.begin()
            bot.goal = goal
            // Commit ownership before scheduling anything that can reach the workspace.
            save()
            guard !turns.saveFailing else {
                bot.goal?.wait("The iteration could not be saved.")
                continue
            }
            let sent = send(text: "Goal step \(goal.iteration) · \(goal.objective)", attachments: files, bot: bot, conversation: bot, replyToID: nil,
                            metadata: [GoalKey.request: goal.request(for: token), GoalKey.attempt: token.uuidString])
            if sent { bot.goal?.initialAttachments = nil; save() } else {
                bot.goal?.wait("The iteration could not start. Check this chat before resuming.")
                save()
            }
        }
    }

    func goalDestination(for bot: Bot) -> ChatGoal.Destination {
        let server = herdrServer(for: bot)
        return .init(serverID: server.id, connection: server.kind, address: server.address,
                     sshHost: server.sshHost, sshUser: server.sshUser,
                     agent: HerdrBackend.agentName(botName: bot.name, botID: bot.id), sessionID: turnSessionID(in: bot, bot: bot))
    }

    func goalDestinationMatches(_ bot: Bot) -> Bool {
        guard let goal = bot.goal else { return false }
        return bot.backend == .herdr && !bot.isDemo && !bot.isReadOnlyArchive && bots.contains(where: { $0 === bot })
            && goal.destination == goalDestination(for: bot)
    }

    func settleGoalTurn(in bot: Bot, attempt: UUID, row: ChatMessage, outcome: TurnOutcome, waitingForPerson: Bool) {
        guard var goal = bot.goal, goal.state == .running, goal.attempt == attempt else { return }
        if outcome.state == .stopped {
            goal.stop()
        } else if waitingForPerson {
            goal.wait("Resolve the workspace prompt, then resume the goal.")
        } else if outcome.state != .finished {
            goal.wait(outcome.reason ?? "The iteration ended without a confirmed result. Check the workspace before resuming.")
        } else if let (report, prose) = ChatGoal.Report.read(row.content, for: attempt) {
            row.metadata[GoalKey.outcome] = report.outcome.rawValue
            row.metadata[GoalKey.evidence] = report.evidence
            row.content = prose.isEmpty ? report.evidence : prose
            let needsAnswer = ChatCardParser.parseVisibleReply(row.content).contains {
                switch $0 {
                case .choices, .multiChoices, .draft: true
                default: false
                }
            } || ChatChoiceInference.options(in: row.content) != nil
            if needsAnswer && report.outcome != .blocked {
                row.metadata[GoalKey.outcome] = ChatGoal.Report.Outcome.blocked.rawValue
                goal.wait("Review the reply in this chat, then resume the goal.")
            } else {
                goal.finish(report)
            }
        } else {
            goal.wait("The reply had no confirmed goal outcome. Review it before resuming.")
        }
        bot.goal = goal
        if goal.state == .queued { turns.scheduledGoals.insert(goal.id) }
    }

    func recoverGoals() {
        for bot in bots {
            guard let goal = bot.goal, isIdle(bot) else { continue }
            switch goal.state {
            case .queued:
                if unconfirmedReply(in: bot) != nil {
                    bot.goal?.wait("An earlier reply is unconfirmed. Review this chat before resuming.")
                    save()
                } else {
                    turns.scheduledGoals.insert(goal.id)
                }
            case .running:
                bot.goal?.wait("SwarmHub closed during this iteration. Check its result before resuming.")
                save()
            default: break
            }
        }
    }
}

enum GoalKey {
    static let attempt = "goalAttemptID"
    static let outcome = "goalOutcome"
    static let evidence = "goalEvidence"
    static let request = "goalIterationRequest"
}
