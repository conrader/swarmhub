import Foundation

extension Bot {
    var offersChatGoal: Bool {
        !isReadOnlyArchive && ((backend == .herdr && !isDemo) || sampleProfile != nil)
    }
}

extension SampleBotProfile {
    func contextPercent(in bot: Bot) -> Int {
        // The interactive preview advances four points for each submitted chat message.
        let turns = bot.messages.lazy.filter { $0.role == .assistant && $0.metadata[TurnKey.forUser] != nil }.prefix(23).count
        return min(92, contextPercent + 4 * turns)
    }
}

extension AppStore {
    /// A sample goal follows local walkthrough events. It never enters the workspace dispatcher.
    func handleSampleGoal(_ command: SlashCommand, bot: Bot, attachments: [ChatAttachment]) -> String? {
        switch command {
        case .start(let objective, let steps, let budget, let perGoal):
            guard attachments.isEmpty else { return "Send attachments in a separate sample chat message." }
            let previous = bot.goal
            var goal: ChatGoal
            if var active = previous, active.state.active {
                guard steps == nil && budget == nil else { return "Stop the current goal before changing its limits." }
                active.objective += "\nFollow-up: " + objective
                goal = active
            } else {
                let server = SampleWorkspace.server
                let destination = ChatGoal.Destination(serverID: server.id, connection: server.kind, address: server.address,
                                                      sshHost: server.sshHost, sshUser: server.sshUser,
                                                      agent: bot.id.uuidString, sessionID: turnSessionID(in: bot, bot: bot))
                goal = ChatGoal(objective: objective, destination: destination, stepLimit: steps)
                goal.budgetUSD = budget ?? (bot.sampleRole == .legal ? 2 : nil)
                if perGoal, budget != nil { goal.stepSpending = .init() }
            }
            guard goal.objective.utf8.count <= HerdrClient.messageBytes else { return "Shorten the sample goal before sending it." }
            let count = bot.messages.count
            let user = ChatMessage(role: .user, content: "/goal " + objective)
            bot.messages.append(user)
            bot.goal = goal
            updateSampleGoal(in: bot, user: user)
            save()
            if turns.saveFailing {
                bot.goal = previous
                bot.messages.removeLast(bot.messages.count - count)
                return "The sample goal could not be saved."
            }
            chatScroll.toBottom(bot.id)
            return nil
        case .status:
            guard let goal = bot.goal else { return "This chat has no goal." }
            let status = goal.state == .waiting ? "Watching sample" : goal.state.rawValue.capitalized
            return [status, goal.objective, goal.stepProgress, goal.spendProgress, goal.detail].compactMap { $0 }.joined(separator: " · ")
        case .stop:
            guard bot.goal?.state.active == true else { return "This chat has no active goal." }
            stopGoal(in: bot)
            return turns.saveFailing ? "The sample goal could not be saved." : nil
        case .invalidBudget: return SlashCommand.budgetUsage
        case .invalidStepLimit: return SlashCommand.stepLimitUsage
        case .commands, .goalUsage:
            return "Use /goal <objective> to follow this sample, /goal status, or /goal stop."
        }
    }

    func updateSampleGoal(in bot: Bot, user: ChatMessage? = nil) {
        guard bot.sampleProfile != nil, var goal = bot.goal, goal.state.active,
              goal.destination.serverID == SampleWorkspace.server.id, goal.destination.agent == bot.id.uuidString else { return }
        // Legal's example starts with six cents of session spend. Local steps add no cost.
        if goal.budgetUSD != nil, goal.stepSpending == nil {
            let balance = ChatGoal.SpendReading(core: SampleWorkspace.core, agent: .init(address: bot.id.uuidString, createdMs: 0),
                                                tokens: 0, usd: bot.sampleRole == .legal ? 0.06 : 0)
            goal.lastSpend = balance
            if let cap = goal.budgetUSD, balance.usd >= cap {
                goal.stop()
                goal.detail = "The sample session reached its spending limit."
            }
        }
        if goal.state.active && !goal.stopAtStepLimit() {
            _ = goal.begin()
            var detail = bot.sampleWalkthrough.map { "\($0.story.title) · Step \($0.step.rawValue) of 3" } ?? bot.title
            if let decision = bot.sampleDecision { detail += " · " + decision.receipt }
            goal.wait(detail)
            _ = goal.stopAtStepLimit()
        }
        bot.goal = goal
        if let user {
            let reply = goal.state.active ? "Goal saved. I’ll track “\(goal.objective)” as you work through this sample. Each local step costs $0." : goal.detail
            bot.messages.append(ChatMessage(role: .assistant, content: reply, metadata: [TurnKey.forUser: user.id.uuidString]))
        }
    }
}
