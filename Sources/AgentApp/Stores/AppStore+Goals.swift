import Foundation

extension AppStore {
    /// The composer passes its own conversation before any steer, queue or attachment delivery.
    func handleGoalCommand(_ command: SlashCommand, in conversation: any Conversation, attachments: [ChatAttachment] = []) -> String? {
        guard openConversation === conversation, openHerdrHelper == nil,
              let bot = conversation as? Bot, bots.contains(where: { $0 === bot }),
              bot.offersChatGoal, persistenceEnabled, storeRestoreOffer == nil
        else { return "Goals require a writable workspace bot chat." }

        if bot.sampleProfile != nil { return handleSampleGoal(command, bot: bot, attachments: attachments) }

        switch command {
        case .start(let objective, let stepLimit, let budget, let perGoal):
            if let current = bot.goal, current.state.active, current.serverGoal != nil {
                // The workspace steps this goal. More words about it are an ordinary message to the bot.
                guard budget == nil, stepLimit == nil else { return "Stop the current goal before starting one with new limits." }
                return send(text: objective, attachments: attachments, bot: bot, conversation: bot, replyToID: replyTo?.id, waitWhenFull: true)
                    ? nil : "The message could not be submitted."
            }
            if bot.goal?.state.active != true, budget == nil, attachments.isEmpty,
               turns.goalServers.contains(herdrServer(for: bot).id) {
                return startServerGoal(objective, stepLimit: stepLimit, in: bot)
            }
            if let current = bot.goal, current.state.active {
                guard budget == nil else { return "Stop the current goal before changing the spending limit." }
                guard stepLimit == nil else { return "Stop the current goal before starting one with a new step limit." }
                if let turn = turn(in: bot), !turn.steerAvailable || turn.stopping {
                    return "This goal step cannot take live guidance. Wait for it to finish before updating the goal."
                }
                return send(text: objective, attachments: attachments, bot: bot, conversation: bot, replyToID: replyTo?.id, waitWhenFull: true, metadata: [GoalKey.amendment: current.id.uuidString])
                    ? nil : "The goal update could not be submitted."
            }
            guard attachments.isEmpty else { return "Start the goal, then attach files to a follow-up." }
            var goal = ChatGoal(objective: objective, destination: goalDestination(for: bot), stepLimit: stepLimit)
            goal.budgetUSD = budget
            if perGoal, budget != nil { goal.stepSpending = .init() }
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
            return [state, goal.stepProgress, goal.spendProgress, goal.objective].compactMap { $0 }.joined(separator: " · ")
        case .stop:
            guard let goal = bot.goal, goal.state.active else { return "This chat has no active goal." }
            stopGoal(in: bot)
            if turns.saveFailing { return "The goal stopped in this window, but the stop could not be saved." }
        case .invalidBudget: return SlashCommand.budgetUsage
        case .invalidStepLimit: return SlashCommand.stepLimitUsage
        case .commands, .goalUsage:
            return "Use /goal [--steps N] [--goal-budget USD | --budget USD] <objective>, /goal status, or /goal stop."
        }
        return nil
    }

    /// The workspace keeps this goal: it types the steps and reads their outcome, so the goal goes on
    /// while SwarmHub is closed or this Mac sleeps. The chat shows what the workspace reports.
    private func startServerGoal(_ objective: String, stepLimit: Int?, in bot: Bot) -> String? {
        var goal = ChatGoal(objective: objective, destination: goalDestination(for: bot), stepLimit: stepLimit)
        goal.serverGoal = 0
        let previous = bot.goal
        bot.goal = goal
        save()
        guard !turns.saveFailing else { bot.goal = previous; return "The goal could not be saved." }
        let id = goal.id, server = herdrServer(for: bot)
        Task {
            do {
                let started = try await herdrClient(for: server).startGoal(objective, stepLimit: stepLimit, for: bot.id)
                guard bot.goal?.id == id, let started else { return }
                bot.goal?.apply(started)
            } catch {
                guard bot.goal?.id == id else { return }
                bot.goal?.stop()
                bot.goal?.detail = "The workspace could not start this goal. \(error.localizedDescription)"
            }
            objectWillChange.send()
            save()
        }
        return nil
    }

    /// Stop and Resume of a goal the workspace keeps.
    private func askServer(about bot: Bot, resume: Bool) {
        guard let id = bot.goal?.id else { return }
        let server = herdrServer(for: bot), botID = bot.id
        Task {
            do {
                let client = try herdrClient(for: server)
                let answer = resume ? try await client.resumeGoal(for: botID) : try await client.stopGoal(for: botID)
                guard let answer, bot.goal?.id == id else { return }
                bot.goal?.apply(answer)
                objectWillChange.send()
                save()
            } catch { return }
        }
    }

    /// What the workspace's feed says about its goals. A goal set from another device is taken up here too.
    func applyServerGoals(_ goals: [HerdrClient.ServerGoal], server: HerdrServer) {
        turns.goalServers.insert(server.id)
        var changed = false
        for item in goals {
            guard let bot = bots.first(where: { $0.id.uuidString.lowercased() == item.bot && $0.backend == .herdr && herdrServer(for: $0) == server }) else { continue }
            if var goal = bot.goal, let known = goal.serverGoal {
                // The request that started it may not have been answered before SwarmHub closed.
                guard known == item.id || (known == 0 && goal.objective == item.objective) else { continue }
                let before = goal
                goal.apply(item)
                if goal != before { bot.goal = goal; changed = true }
            } else if bot.goal?.state.active != true, ["queued", "running", "waiting"].contains(item.state) {
                var goal = ChatGoal(objective: item.objective, destination: goalDestination(for: bot), stepLimit: item.stepLimit)
                goal.apply(item)
                bot.goal = goal
                changed = true
            }
        }
        if changed { objectWillChange.send(); save() }
    }

    func resumeGoal(in bot: Bot) {
        if bot.goal?.serverGoal != nil {
            guard bot.goal?.state == .waiting else { return }
            askServer(about: bot, resume: true)
            return
        }
        guard openConversation === bot, bot.goal?.state == .waiting, isIdle(bot),
              goalDestinationMatches(bot), !herdrWaits(bot).waits else { return }
        bot.goal?.resume()
        if let id = bot.goal?.id { turns.scheduledGoals.insert(id) }
        save()
        sendQueuedNextMessage()
    }

    func stopGoal(in bot: Bot) {
        guard let goal = bot.goal, goal.state.active else { return }
        if goal.serverGoal != nil {
            bot.goal?.stop()
            save()
            askServer(about: bot, resume: false)
            return
        }
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

    /// A step whose result was recovered after the app was closed can leave the goal ready for its next
    /// step. Hand it to the normal dispatcher, which checks prompts, limits and budget before it sends.
    func continueRecoveredGoal(in bot: Bot) {
        guard let goal = bot.goal, goal.serverGoal == nil, goal.state == .queued, !turns.scheduledGoals.contains(goal.id),
              unconfirmedReply(in: bot) == nil else { return }
        turns.scheduledGoals.insert(goal.id)
        save()
        sendQueuedNextMessage()
    }

    /// The status of a goal that has ended leaves the chat. `/goal status` still reports it.
    func dismissGoal(in bot: Bot) {
        guard let goal = bot.goal, !goal.state.active, goal.dismissed != true else { return }
        bot.goal?.dismissed = true
        save()
    }

    /// Called by the normal queue drain, after messages waiting for a slot had their turn.
    func dispatchQueuedGoals(checkedGoal: UUID? = nil, spend: ChatGoal.SpendReading? = nil) {
        guard persistenceEnabled, storeRestoreOffer == nil else { return }
        // A goal that paused only for a workspace prompt is scheduled again once the prompt is gone.
        for bot in bots where bot.goal?.state == .waiting && bot.goal?.resumesWhenClear == true {
            guard isIdle(bot), goalDestinationMatches(bot), !herdrWaits(bot).waits, herdrPrompts[bot.id] == nil,
                  let id = bot.goal?.id else { continue }
            bot.goal?.resume()
            turns.scheduledGoals.insert(id)
            save()
        }
        guard !turns.scheduledGoals.isEmpty else { return }
        for bot in bots {
            guard var goal = bot.goal, goal.state == .queued, turns.scheduledGoals.contains(goal.id),
                  isIdle(bot), turns.pendingInterrupts[bot.id] == nil, !hasWaitingTurn(in: bot), turnCapacityProblem(for: [bot]) == nil else { continue }
            turns.scheduledGoals.remove(goal.id)
            if goal.stopAtStepLimit() || goal.stopAtGoalSpendingLimit() {
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
                bot.goal?.waitForPrompt()
                save()
                continue
            }
            guard pendingHerdrBots(for: bot).isEmpty, pendingHerdrModels(for: bot).isEmpty else {
                bot.goal?.wait("Review the pending request in this chat, then resume the goal.")
                save()
                continue
            }
            if goal.budgetUSD != nil {
                if checkedGoal != goal.id {
                    if turns.checkingGoalSpend.insert(goal.id).inserted {
                        Task { await checkGoalSpend(goal, bot: bot) }
                    }
                    continue
                }
                guard goal.permitsNextStep(spend: spend) else {
                    bot.goal = goal
                    save()
                    continue
                }
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
                bot.goal?.stepSpending?.pending = nil
                bot.goal?.stepSpending?.attempt = nil
                bot.goal?.wait("The iteration could not start. Check this chat before resuming.")
                save()
            }
        }
    }

    private func checkGoalSpend(_ goal: ChatGoal, bot: Bot) async {
        let reading = await readGoalSpend(goal, bot: bot)
        turns.checkingGoalSpend.remove(goal.id)
        guard bot.goal?.id == goal.id, bot.goal?.iteration == goal.iteration, bot.goal?.state == .queued,
              bots.contains(where: { $0 === bot }) else { return }
        turns.scheduledGoals.insert(goal.id)
        dispatchQueuedGoals(checkedGoal: goal.id, spend: reading)
    }

    private func readGoalSpend(_ goal: ChatGoal, bot: Bot) async -> ChatGoal.SpendReading? {
        do {
            let client = try herdrClient(for: herdrServer(for: bot))
            let workspace: HerdrClient.Workspace = try await client.get("/api/workspace", timeout: 3)
            let live = workspace.agents.filter { $0.isLive && $0.name == goal.destination.agent }
            guard let core = workspace.core, live.count == 1, let agent = live.first,
                  let usage = agent.sessionUsage, let usd = usage.opencodeCostUsd else { return nil }
            return .init(core: core, agent: agent.ref, tokens: usage.totalTokens, usd: usd)
        } catch { return nil }
    }

    /// Sample before releasing the turn slot so another chat message cannot enter the interval.
    func recordGoalStepCost(in bot: Bot, goalID: UUID, iteration: Int) async {
        guard let goal = bot.goal, goal.id == goalID, goal.iteration == iteration,
              goal.stepSpending?.pending != nil, goalDestinationMatches(bot) else { return }
        for attempt in 0..<3 {
            let reading = await readGoalSpend(goal, bot: bot)
            guard bot.goal?.id == goalID, bot.goal?.iteration == iteration, goalDestinationMatches(bot) else { return }
            if bot.goal?.recordStepCost(reading) == true || reading == nil || attempt == 2 { return }
            // The workspace can publish its usage event just after the reply.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
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
        let parsed = ChatGoal.Report.read(row.content, for: attempt)
        if let parsed { row.displayGoalResult(parsed.report, prose: parsed.prose) }
        guard var goal = bot.goal, goal.state == .running, goal.attempt == attempt else { return }
        if outcome.state == .stopped {
            goal.stop()
        } else if waitingForPerson {
            goal.wait("Resolve the workspace prompt, then resume the goal.")
        } else if outcome.state != .finished {
            goal.wait(outcome.reason ?? "The iteration ended without a confirmed result. Check the workspace before resuming.")
        } else if let report = parsed?.report {
            if row.asksForAnswer && report.outcome != .blocked {
                row.metadata[GoalKey.outcome] = ChatGoal.Report.Outcome.blocked.rawValue
                goal.wait("Review the reply in this chat, then resume the goal.")
            } else {
                let assessed = goal.finish(report)
                row.metadata[GoalKey.outcome] = assessed.outcome.rawValue
                row.metadata[GoalKey.evidence] = assessed.evidence
            }
        } else {
            goal.wait("The reply had no confirmed goal outcome. Review it before resuming.")
        }
        bot.goal = goal
        if goal.state == .queued { turns.scheduledGoals.insert(goal.id) }
    }

    /// A report from a routine can arrive while the goal is waiting for an unrelated approval.
    /// Only the bot's own recent journal reply can initiate a check. The normal goal dispatcher
    /// enforces destination, pending prompts, step limits and budget before it sends anything.
    @discardableResult
    func checkReportedCompletion(in bot: Bot, reply: ChatMessage) -> Bool {
        guard var goal = bot.goal, goal.state == .waiting,
              let (target, unit) = goal.freeSpaceThreshold,
              reply.role == .assistant, reply.metadata[GoalKey.attempt] == nil,
              reply.metadata["herdrJournal"]?.hasPrefix(goal.destination.serverID + ":") == true,
              reply.metadata["herdrTeamEntry"]?.hasPrefix(goal.destination.serverID + ":") == true,
              goalDestinationMatches(bot) else { return false }
        let lead = String(reply.content.prefix(420)).replacingOccurrences(of: "*", with: "")
        guard let assertion = lead.firstMatch(of: #/(?i)^\s*(?:cel|goal|target|objective)\b[^.!?\n]{0,110}?(?:osiągnięty|osiagniety|achieved|reached|met)\b/#),
              assertion.0.firstMatch(of: #/(?i)\b(?:not|never|nie|jeszcze|if|gdyby)\b/#) == nil,
              let amount = assertion.0.firstMatch(of: #/(?i)\b([0-9]+(?:[,.][0-9]+)?)\s*(KiB|MiB|GiB|TiB|KB|MB|GB|TB)\b/#),
              Double(amount.1.replacingOccurrences(of: ",", with: ".")) == target,
              String(amount.2).caseInsensitiveCompare(unit) == .orderedSame,
              let last = bot.messages.last(where: { $0.role == .user && $0.metadata[GoalKey.attempt] != nil }),
              last.createdAt < reply.createdAt,
              let token = last.metadata[GoalKey.attempt].flatMap(UUID.init(uuidString:)),
              let prior = bot.messages.last(where: { $0.role == .assistant && $0.metadata[GoalKey.attempt] == token.uuidString }),
              prior.metadata[GoalKey.outcome] == ChatGoal.Report.Outcome.blocked.rawValue,
              goal.detail == prior.metadata[GoalKey.evidence].map({ String($0.prefix(800)) }),
              let sent = last.metadata[GoalKey.request],
              goal.lastBeganAttempt.map({ $0 == token }) ?? goal.matchesSavedRequest(sent, token: token) else { return false }
        goal.completionObservation = .init(reportedAt: reply.createdAt, excerpt: lead)
        guard goal.request(for: UUID()).utf8.count <= HerdrClient.messageBytes else { return false }
        goal.state = .queued
        bot.goal = goal
        turns.scheduledGoals.insert(goal.id)
        return true
    }

    func recoverGoals() {
        for bot in bots {
            // A goal the workspace keeps went on without this Mac; the feed brings its state.
            guard let goal = bot.goal, goal.serverGoal == nil, isIdle(bot) else { continue }
            switch goal.state {
            case .queued:
                if unconfirmedReply(in: bot) != nil {
                    bot.goal?.wait("An earlier reply is unconfirmed. Review this chat before resuming.")
                    save()
                } else {
                    turns.scheduledGoals.insert(goal.id)
                }
            case .running:
                bot.goal?.interruptedAttempt = goal.attempt
                bot.goal?.wait(ChatGoal.interruptedDetail)
                save()
            case .waiting:
                if bot.messages.reversed().contains(where: { checkReportedCompletion(in: bot, reply: $0) }) { save() }
            default: break
            }
        }
    }
}

enum GoalKey {
    static let attempt = "goalAttemptID"
    static let outcome = "goalOutcome"
    static let evidence = "goalEvidence"
    static let amendment = "goalAmendment"
    static let guidance = "goalStepGuidance"
    static let request = "goalIterationRequest"
}
