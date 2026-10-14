import Foundation

/// P16: a group round and one member's turn. Members answer one after another; every member the round did not reach
/// gets a `notSent` row, so nothing is skipped without a trace.
extension AppStore {
    func runGroupRound(group: GroupChat, run: GroupRun, token: UUID, recipients: [UUID], images: [String], trigger: ChatMessage) async {
        var skipped: [UUID] = []; var skipWhy = "stopped"
        for (index, botID) in recipients.enumerated() {
            let rest = Array(recipients[index...])
            if run.stopped || Task.isCancelled { skipped = rest; skipWhy = "stopped"; break }
            // A round starts no member's turn while the path is down.
            if turns.pathDown { skipped = rest; skipWhy = "offline"; break }
            group.round?.remaining.removeAll { $0 == botID }
            guard group.memberIDs.contains(botID), let bot = bots.first(where: { $0.id == botID }) else { save(); continue }
            group.round?.active = botID; save()
            let outcome = await groupTurn(bot: bot, group: group, run: run, token: token, images: images, trigger: trigger)
            group.round?.active = nil; save()
            if case .stopsRest(let why)? = outcome?.round, index + 1 < recipients.count { skipped = Array(recipients[(index + 1)...]); skipWhy = why; break }
        }
        markSkipped(skipped, in: group, trigger: trigger, why: skipWhy)
        group.round = nil; group.activeMemberID = nil
        if activeStreamToken == token {
            isStreaming = false; streamTask = nil; activeStreamToken = nil; streamingBotID = nil; streamingAssistant = nil; streamingConversation = nil; steerAvailable = false
        }
        if groupRun === run { groupRun = nil }
        objectWillChange.send(); save()
        sendQueuedNextMessage()
    }

    /// Members the round did not ask: a `notSent` row each (Retry lives there) and one line naming them.
    func markSkipped(_ ids: [UUID], in group: GroupChat, trigger: ChatMessage, why: String) {
        let members = ids.compactMap { id in group.memberIDs.contains(id) ? bots.first { $0.id == id } : nil }
        guard !members.isEmpty else { return }
        for bot in members {
            group.messages.append(ChatMessage(role: .assistant, content: "", metadata: [TurnKey.forUser: trigger.id.uuidString, TurnKey.why: why], authorID: bot.id, turnState: .notSent))
        }
        let names = members.map(\.name).joined(separator: ", ")
        let line = why == "stopped" ? "Stopped. Skipped: \(names)." : why == "quit" ? "\(AppConstants.name) quit before \(names) were asked. Retry on their rows." : "Not sent to \(names) (\(why))."
        group.messages.append(ChatMessage(role: .system, content: line, metadata: [TurnKey.tone: "warning"]))
        objectWillChange.send()
    }

    /// One member's turn in its own group session. `reusing` is a `notSent` row Retry sends into.
    @discardableResult func groupTurn(bot: Bot, group: GroupChat, run: GroupRun, token: UUID, images: [String], trigger: ChatMessage, reusing row: ChatMessage? = nil) async -> TurnOutcome? {
        if needsKey(bot) { group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: no key for \(bot.hermesProfile ?? "its profile").")); return nil }
        let activeBackend: any AgentBackend
        do { activeBackend = try backend(for: bot) } catch { group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: \(error.localizedDescription)")); return nil }
        let context = GroupRouting.context(for: .init(id: bot.id, name: bot.name), groupName: group.name, members: routingMembers(of: group), messages: group.messages, current: trigger.id, userName: userName)
        let assistant: ChatMessage
        if let row {
            assistant = row; row.isStreaming = true; row.turnState = .incomplete
            [TurnKey.why, TurnKey.ambiguous, TurnKey.check, TurnKey.retry, TurnKey.end].forEach { row.metadata[$0] = nil }
        } else {
            assistant = ChatMessage(role: .assistant, content: "", isStreaming: true, metadata: [TurnKey.forUser: trigger.id.uuidString], authorID: bot.id, turnState: .incomplete)
            group.messages.append(assistant)
        }
        group.activeMemberID = bot.id
        if activeStreamToken == token { streamingBotID = bot.id; streamingAssistant = assistant }
        objectWillChange.send(); save()
        let wanted = sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id)
        var end: TurnEnd; var refused = false
        do {
            if group.session(for: bot.id) == nil, try await activeBackend.sessionTransport() == .nativeSessions {
                let note = { [unowned self] (text: String) in insertNote(text, in: group, before: assistant) }
                let plan = try await prepareModel(for: bot, backend: activeBackend, note: note)
                let created = try await activeBackend.createSession(title: "\(group.name) · \(bot.name)", systemPrompt: bot.persona, id: wanted)
                if let plan { try await applyModel(plan, bot: bot, sessionID: created, record: false, note: note) }
                group.hermesSessionID = created
                save()
            }
            try Task.checkCancellation()
            let sessionID = group.session(for: bot.id) ?? wanted
            let stream = try await activeBackend.send(.init(sessionID: sessionID, systemPrompt: bot.persona, messages: [(role: "user", content: context)], images: images))
            if activeStreamToken == token { steerAvailable = (try? await activeBackend.features())?.contains("run_steer") == true }
            end = try await consumeTurn(stream, assistant: assistant, bot: bot, sessionID: sessionID, backend: activeBackend) { [unowned self] task in subAgentTasks[bot.id, default: []].append(task) }
        } catch is CancellationError { end = .stoppedByUser
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled { end = .stoppedByUser
        } catch let refusal as ModelRefusal {
            group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: \(refusal.text)")); end = .error(refusal); refused = true
        } catch { end = .error(error) }
        if Task.isCancelled || run.stopped, case .completed = end {} else if Task.isCancelled || run.stopped { end = .stoppedByUser }
        let (reply, steers) = endTurnParts(assistant)
        if case .stoppedByUser = end, reply.turnState != .stopped { reply.turnState = .stopped; reply.metadata[TurnKey.why] = "stopped" }
        let outcome = finishTurn(end, assistant: reply, bot: bot, in: group, backend: activeBackend, alertPrefix: "\(bot.name): ", warn: !refused, alert: !refused)
        let cancelled = outcome.state == .stopped
        let session = group.session(for: bot.id) ?? wanted
        let abandoned = approvals.filter { $0.botID == bot.id && $0.sessionID == session }
        for approval in abandoned {
            appendAudit(to: bot, approval: approval, outcome: .denied, decidedBy: "system", reason: cancelled ? "Run stopped; pending approval was cancelled." : "Run ended; pending approval was cancelled.")
        }
        approvals.removeAll { abandoned.map(\.id).contains($0.id) }
        group.activeMemberID = nil
        if activeStreamToken == token { steerAvailable = false }
        let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && (outcome.state == .finished || outcome.state == .incomplete) && selectedGroup?.id != group.id { group.unreadCount += 1 }
        if outcome.state == .finished && !text.isEmpty {
            AvatarReactions.shared.completed(bot)
            notifyIfNeeded(group: group, bot: bot, message: text)
        }
        resendReturnedSteers(steers, bot: nil)
        objectWillChange.send(); save()
        return outcome
    }
}
