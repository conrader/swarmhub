import Foundation

struct MoveCheckpoint {
    let turn: UUID
    let row: ChatMessage
    let request: ChatMessage
    let receipt: HerdrDeliveryReceipt
    let agent: HerdrClient.AgentRef
}

extension AppStore {
    /// Only interrupt work for which we have both the actual request and its live direct session.
    func moveCheckpoint(for bot: Bot, agents: [HerdrClient.Agent], workspace: HerdrClient.Workspace) -> MoveCheckpoint? {
        guard let turn = turn(in: bot), !turn.stopping, turn.goalAttempt == nil, bot.goal?.state.active != true,
              let row = turn.assistant, let receipt = row.deliveryReceipt, let request = trigger(of: row, in: bot), !request.isDraftApproval,
              !herdrWaits(bot).waits, !herdrHasUnansweredHelpers(bot),
              let directName = herdrExistingAgentNames(for: bot).first,
              let agent = agents.first(where: { $0.name == directName || HerdrClient.suffix(of: $0.name) == HerdrClient.suffix(of: directName) }),
              receipt.server == herdrServer(for: bot).id, receipt.core == workspace.core,
              receipt.address == agent.address, receipt.createdMs == agent.createdMs,
              agent.status?.state == "working", agent.firstMessage?.sent != false,
              !workspace.agents.contains(where: { $0.isLive && $0.parent == agent.ref }),
              !agents.contains(where: { $0.ref != agent.ref && herdrAgentIsBusy($0, in: workspace.agents) }),
              !runningTurns.values.contains(where: { $0.botID == bot.id && $0 !== turn }) else { return nil }
        return MoveCheckpoint(turn: turn.token, row: row, request: request, receipt: receipt, agent: agent.ref)
    }

    func interruptForMove(_ bot: Bot, checkpoint: MoveCheckpoint, source: HerdrServer, core: String, client: HerdrClient) async throws -> Bool {
        guard case .waiting = try await checkpoint.receipt.read(from: client) else { throw HerdrMoveError.selectionChanged }
        let roster = try await client.workspace(includingCodejobs: true)
        guard roster.core == core, herdrServer(for: bot) == source,
              let turn = turn(in: bot), turn.token == checkpoint.turn, turn.assistant === checkpoint.row,
              !turn.stopping, let live = roster.agents.first(where: { $0.ref == checkpoint.agent && $0.isLive }),
              live.status?.state == "working", !roster.agents.contains(where: { $0.isLive && $0.parent == live.ref }),
              roster.codejobActivity?.hosts?.contains(where: { $0.jobs.contains { $0.owner == bot.id } }) != true
        else { throw HerdrMoveError.selectionChanged }

        stop(bot)
        let deadline = ContinuousClock.now + .seconds(20)
        while !isIdle(bot) || turns.pendingInterrupts[bot.id] != nil {
            guard ContinuousClock.now < deadline else { throw BackendError.unavailable("The source has not confirmed the interruption. The bot is still on " + source.name + ".") }
            try await Task.sleep(for: .milliseconds(150))
        }
        let after = try await client.workspace()
        guard checkpoint.row.metadata[TurnKey.why] == "stopped", checkpoint.row.turnState == .stopped,
              after.core == core, herdrServer(for: bot) == source,
              after.agents.first(where: { $0.ref == live.ref && $0.isLive }).map({ $0.isIdleForRollover }) ?? true,
              !after.agents.contains(where: { $0.isLive && $0.parent == live.ref })
        else { throw BackendError.unavailable("Could not confirm that the source task stopped. The bot is still on " + source.name + ".") }

        switch try await checkpoint.receipt.read(from: client) {
        case .answered(let item, let results):
            // The source finished between the last check and the interrupt.
            restoreSavedAnswer(item, results: results, for: checkpoint.row, in: bot, group: nil, serverID: source.id)
            await refreshHerdrHelpers(on: source.id)
            save()
            return false
        case .unresolved: throw HerdrMoveError.selectionChanged
        case .waiting: break
        }
        var text = "Continue the interrupted task from the last verified step. Check which actions already completed before continuing.\n\nOriginal request:\n" + checkpoint.request.content
        if !checkpoint.row.content.isEmpty { text += "\n\nProgress before interruption:\n" + checkpoint.row.content }
        let continuation = ChatMessage(role: .user, content: text, replyToID: checkpoint.request.id, attachments: checkpoint.request.attachments)
        bot.messages.append(continuation)
        guard waitForTurn(continuation, in: bot, reason: "Waiting for the server move to finish.") else { throw HerdrMoveError.saveFailed }
        await refreshHerdrHelpers(on: source.id)
        return true
    }
}
