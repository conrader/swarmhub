import Foundation

/// A group round and one member's turn. Members answer one after another; every member the round did not reach
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
            guard group.memberIDs.contains(botID), let bot = bots.first(where: { $0.id == botID && !$0.isReadOnlyArchive }) else { save(); continue }
            group.round?.active = botID; save()
            let outcome = await groupTurn(bot: bot, group: group, run: run, token: token, images: images, trigger: trigger)
            group.round?.active = nil; save()
            if case .stopsRest(let why)? = outcome?.round, index + 1 < recipients.count { skipped = Array(recipients[(index + 1)...]); skipWhy = why; break }
        }
        markSkipped(skipped, in: group, trigger: trigger, why: skipWhy)
        group.round = nil; group.activeMemberID = nil
        endTurn(token)
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

    /// One member's turn. `reusing` is a `notSent` row Retry sends into.
    @discardableResult func groupTurn(bot: Bot, group: GroupChat, run: GroupRun, token: UUID, images: [String], trigger: ChatMessage, reusing row: ChatMessage? = nil) async -> TurnOutcome? {
        // A saved document whose access was removed after the round started is never sent to this member.
        do { try validateArtifactAccess(trigger, botID: bot.id) } catch { group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: \(error.localizedDescription)")); return nil }
        let activeBackend: any AgentBackend
        do { activeBackend = try backend(for: bot) } catch { group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: \(error.localizedDescription)")); return nil }
        let assistant: ChatMessage
        if let row {
            assistant = row; row.isStreaming = true; row.turnState = .incomplete
            [TurnKey.why, TurnKey.ambiguous, TurnKey.retry, TurnKey.end].forEach { row.metadata[$0] = nil }
        } else {
            assistant = ChatMessage(role: .assistant, content: "", isStreaming: true, metadata: [TurnKey.forUser: trigger.id.uuidString], authorID: bot.id, turnState: .incomplete)
            group.messages.append(assistant)
        }
        group.activeMemberID = bot.id
        if let turn = turn(token: token) { turn.botID = bot.id; turn.assistant = assistant; turn.backend = activeBackend }
        objectWillChange.send(); save()
        let sessionID = turnSessionID(in: group, bot: bot)
        var end: TurnEnd
        do {
            try Task.checkCancellation()
            let member = GroupRouting.Member(id: bot.id, name: bot.name)
            let members = routingMembers(of: group), messages = readableMessages(group.messages, for: bot.id)
            let herdr = activeBackend as? HerdrBackend
            let files = herdr == nil ? [] : try trigger.attachments.map(attachmentEncoder.taskFile(for:))
            let context: String
            if let herdr {
                let limit = groupMessageBudget(herdr, hasFiles: !files.isEmpty)
                context = try GroupRouting.herdrContext(for: member, groupName: group.name, members: members,
                    messages: messages, current: trigger, limit: limit, userName: userName)
            } else {
                context = GroupRouting.context(for: member, groupName: group.name, members: members,
                    messages: messages, current: trigger.id, userName: userName)
            }
            let stream = try await activeBackend.send(.init(sessionID: sessionID, systemPrompt: bot.outboundPersona,
                messages: [(role: "user", content: context)], images: herdr == nil ? images : [], files: files))
            if isCurrent(token) { setSteerAvailable((try? await activeBackend.features())?.contains("run_steer") == true, token: token) }
            end = try await consumeTurn(stream, assistant: assistant, bot: bot, group: group)
        } catch is CancellationError { end = .stoppedByUser
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled { end = .stoppedByUser
        } catch { end = .error(error) }
        if Task.isCancelled || run.stopped, case .completed = end {} else if Task.isCancelled || run.stopped { end = .stoppedByUser }
        let reply = endTurnParts(assistant)
        if case .stoppedByUser = end, reply.turnState != .stopped { reply.turnState = .stopped; reply.metadata[TurnKey.why] = "stopped" }
        let outcome = finishTurn(end, assistant: reply, bot: bot, in: group, alertPrefix: "\(bot.name): ")
        group.activeMemberID = nil
        if let turn = turn(token: token) { turn.botID = nil; turn.backend = nil }
        setSteerAvailable(false, token: token)
        let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !reply.isSilent && (outcome.state == .finished || outcome.state == .incomplete) && selectedGroup?.id != group.id { group.unreadCount += 1 }
        if outcome.state == .finished && !text.isEmpty {
            AvatarReactions.shared.completed(bot)
            notifyIfNeeded(group: group, bot: bot, message: reply.finalText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        objectWillChange.send(); save()
        return outcome
    }
}
