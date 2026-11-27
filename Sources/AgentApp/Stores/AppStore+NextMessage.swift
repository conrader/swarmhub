import Foundation

/// A failed steer's text (or a review's notes) waiting for the running turn to end. P38 E: kept in the run ledger too
/// (`AppStore+QueueRecovery.swift`); `restored` entries came back from a quit and wait for the launch reconcile.
struct QueuedNextMessage {
    var id = UUID()
    let conversation: any Conversation
    let bubble: ChatMessage
    var kind: NextMessageRecord.Kind = .steer
    var anchorID: UUID
    /// Only the original live reply may take this waiting message as guidance. Relaunch uses the normal queue.
    var startupTarget: StartupSteerTarget?
    let predecessor: QueuePredecessor
    var restored = false
    init(id: UUID = UUID(), conversation: any Conversation, bubble: ChatMessage, kind: NextMessageRecord.Kind = .steer, anchorID: UUID? = nil,
         predecessor: QueuePredecessor = .conversation, restored: Bool = false) {
        self.id = id; self.conversation = conversation; self.bubble = bubble; self.kind = kind; self.anchorID = anchorID ?? bubble.id
        self.predecessor = predecessor; self.restored = restored
    }
}

/// P32 item 9: a steer that was not delivered ("failed") offers "Send as next message". Its text goes out as a normal
/// message in the same chat, thread or group: at once when nothing runs, else once the running turn or round ends.
/// The original user row becomes the trigger for its own turn.
extension AppStore {
    /// The button captures the claim ID so an old click cannot remove a newer send of the same row.
    func waitingDirectClaim(for bubble: ChatMessage) -> QueuedNextMessage? {
        guard storeRestoreOffer == nil, bubble.role == .user, !bubble.isSteer,
              bubble.metadata[TurnWaitCopy.key] == "waiting", !turns.inFlightSteers.contains(bubble.id),
              let next = turns.nextMessages.first(where: { $0.bubble === bubble }),
              next.kind == .turn, next.predecessor != .conversation, let bot = next.conversation as? Bot,
              bots.contains(where: { $0 === bot }), bot.messages.contains(where: { $0 === bubble }),
              !bot.messages.contains(where: { $0.role == .assistant && $0.metadata[TurnKey.forUser] == bubble.id.uuidString })
        else { return nil }
        return next
    }

    @discardableResult func cancelQueuedSend(_ claim: QueuedNextMessage) -> Bool {
        guard waitingDirectClaim(for: claim.bubble)?.id == claim.id else { return false }
        var returned = [claim], claimIDs: Set<UUID> = [claim.id], bubbleIDs: Set<UUID> = [claim.bubble.id]
        // Resolve only descendants. Cancelling a wait must never launch other ready work.
        for next in turns.nextMessages where next.conversation === claim.conversation {
            guard case .message(let prior) = next.predecessor, bubbleIDs.contains(prior),
                  waitingDirectClaim(for: next.bubble)?.id == next.id,
                  resolvePredecessor(for: next, removing: claimIDs) == .giveBack else { continue }
            returned.append(next)
            claimIDs.insert(next.id)
            bubbleIDs.insert(next.bubble.id)
        }
        func warning(for id: UUID) -> String {
            id == claim.id ? TurnWaitCopy.cancelled : TurnWaitCopy.predecessorNotConfirmed
        }
        if persistenceEnabled {
            do {
                let ledger = try journal()
                let records = try ledger.records(NextMessageRecord.self, kind: Self.nextMessageKind)
                let claims = records.filter { bubbleIDs.contains($0.anchorID) && $0.state != .removed }
                guard claims.count == returned.count, claims.allSatisfy({ claimIDs.contains($0.id) && $0.state == .waiting }) else {
                    throw BackendError.unavailable("The queued send changed. Reopen the chat before trying again.")
                }
                try ledger.putMany(claims.map { record in
                    var copy = record
                    copy.state = .removed
                    copy.returnWarning = warning(for: copy.id)
                    return (id: copy.id.uuidString, value: copy)
                }, kind: Self.nextMessageKind)
            } catch {
                errorMessage = "Could not save the message queue: \(error.localizedDescription)"
                return false
            }
        }
        turns.nextMessages.removeAll { claimIDs.contains($0.id) }
        for next in returned { giveBackBubble(next, warning: warning(for: next.id)) }
        objectWillChange.send()
        save()
        return true
    }

    /// Shown under a failed steer bubble that is not already waiting (a "next" left over from a quit counts as failed).
    func canSendAsNextMessage(_ bubble: ChatMessage) -> Bool {
        guard bubble.role == .user, let state = bubble.metadata[SteerKey.steer] else { return false }
        let waiting = turns.nextMessages.contains { $0.bubble === bubble }
        return (state == "failed" || state == "next" && !waiting) && conversation(containing: bubble.id) != nil
    }

    /// "Send as next message" pressed. False when the bubble is not a failed steer or its chat can't send.
    @discardableResult func sendAsNextMessage(_ bubble: ChatMessage) -> Bool {
        guard canSendAsNextMessage(bubble), let conversation = conversation(containing: bubble.id) else { return false }
        bubble.metadata[SteerKey.explicitNext] = "1"
        bubble.metadata[SteerKey.steer] = "next"
        guard enqueueNextMessage(QueuedNextMessage(conversation: conversation, bubble: bubble)) else { bubble.metadata[SteerKey.steer] = "failed"; return false }
        objectWillChange.send(); save()
        sendQueuedNextMessage()
        return true
    }

    /// Sends the oldest waiting text when no turn runs; called again whenever a turn or round ends. A chat that can no
    /// longer send puts its bubble back to "failed" (the button returns) and the next one is tried.
    /// The ledger records submission before dispatch. Restored entries also wait for launch reconciliation.
    /// P39: per chat. Each chat's oldest entry goes once that chat has no turn and the turn limits allow it; a chat's later
    /// entries wait behind its first, and a restored entry holds its own chat only.
    func sendQueuedNextMessage() {
        guard storeRestoreOffer == nil else { return }
        defer { dispatchQueuedGoals() }
        var held: Set<UUID> = []; var index = 0
        while index < turns.nextMessages.count {
            let next = turns.nextMessages[index], key = next.conversation.id
            guard !held.contains(key), !next.restored, turns.pendingInterrupts[key] == nil else {
                held.insert(key); index += 1; continue
            }
            // A stale waiting claim can coexist with a Retry or another claim for the same row.
            // Once its own reply exists, the turn (including any Retry) owns delivery.
            if next.kind == .turn, next.conversation is Bot, next.predecessor != .conversation {
                let hasReply = next.conversation.messages.contains { $0.role == .assistant && $0.metadata[TurnKey.forUser] == next.bubble.id.uuidString }
                if hasReply || next.bubble.metadata[TurnWaitCopy.key] != "waiting" {
                    endWait(next.bubble, in: next.conversation)
                    objectWillChange.send(); save()
                    guard !turns.saveFailing, recordNextMessage(next, .removed) else { break }
                    turns.nextMessages.remove(at: index)
                    continue
                }
            }
            switch resolvePredecessor(for: next) {
            case .ready: break
            case .waiting:
                held.insert(key); index += 1; continue
            case .giveBack:
                giveBackBubble(next, warning: TurnWaitCopy.predecessorNotConfirmed)
                save()
                guard !turns.saveFailing, recordNextMessage(next, .removed) else { return }
                turns.nextMessages.remove(at: index)
                continue
            }
            guard isIdle(next.conversation), turnCapacityProblem(for: waitingBots(next)) == nil else {
                held.insert(key); index += 1; continue
            }
            if let serverID = next.bubble.metadata[TurnWaitCopy.promptServer], let bot = next.conversation as? Bot {
                checkPromptQueue(next, bot: bot, serverID: serverID)
                held.insert(key); index += 1; continue
            }
            guard recordNextMessage(next, .submitting) else { break }
            turns.nextMessages.remove(at: index)
            if startNextMessage(next) {
                // Retire the queue claim only after the local turn and its retry path are durable.
                // A crash before the save leaves the submission uncertain.
                save()
                guard !turns.saveFailing, recordNextMessage(next, .removed) else { continue }
                held.insert(key); continue
            }
            recordNextMessage(next, .removed)
            if next.kind == .turn { giveBackBubble(next) } else { next.bubble.metadata[SteerKey.steer] = "failed" }
            objectWillChange.send(); save()
        }
    }

    private func checkPromptQueue(_ next: QueuedNextMessage, bot: Bot, serverID: String) {
        guard turns.checkingPromptQueues.insert(next.id).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            // Re-enter the normal drain, which only dispatches claims still in the queue.
            defer { turns.checkingPromptQueues.remove(next.id); sendQueuedNextMessage() }
            guard turns.nextMessages.contains(where: { $0.id == next.id }) else { return }
            guard bots.contains(bot) else {
                turns.nextMessages.removeAll { $0.id == next.id }
                recordNextMessage(next, .removed)
                return
            }
            let server = herdrServer(for: bot)
            guard server.id == serverID else {
                turns.nextMessages.removeAll { $0.id == next.id }
                giveBack(next)
                save()
                return
            }
            guard let client = try? herdrClient(for: server), let workspace = try? await client.workspace(),
                  workspace.core != nil, herdrServer(for: bot) == server,
                  turns.nextMessages.contains(where: { $0.id == next.id }) else { return }
            let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
            if let agent = client.liveAgent(named: name, in: workspace) {
                guard agent.status?.state == "idle" || agent.status?.state == "done" else { return }
            }
            next.bubble.metadata[TurnWaitCopy.promptServer] = nil
        }
    }

    private func startNextMessage(_ next: QueuedNextMessage) -> Bool {
        let user = next.bubble
        guard next.conversation.messages.contains(where: { $0 === user }) else { return false }
        let images: [String]
        do { images = try user.attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) }
        catch { presentError(error.localizedDescription, reason: .attachment); return false }
        if let group = next.conversation as? GroupChat {
            guard groups.contains(where: { $0 === group }) else { return false }
            let recipients = queuedRecipients(user, in: group)
            guard !recipients.isEmpty, recipients.allSatisfy({ (try? validateArtifactAccess(user, botID: $0)) != nil }) else { return false }
            prepareQueuedRow(next)
            return startGroupRound(group, message: user, recipients: recipients, images: images)
        }
        guard let bot = next.conversation as? Bot, bots.contains(where: { $0 === bot }), !bot.isReadOnlyArchive,
              let activeBackend = try? backend(for: bot),
              (try? validateArtifactAccess(user, botID: bot.id)) != nil else { return false }
        if let attempt = user.metadata[GoalKey.attempt],
           bot.goal?.attempt?.uuidString != attempt || !goalDestinationMatches(bot) { return false }
        prepareQueuedRow(next)
        return startChatTurn(bot: bot, conversation: next.conversation, user: user, images: images, backend: activeBackend)
    }

    private func prepareQueuedRow(_ next: QueuedNextMessage) {
        let conversation = next.conversation, row = next.bubble
        if next.kind == .turn {
            endWait(row, in: conversation)
            return
        }
        // Keep the ID, quote, recipients and attachments when a failed steer becomes a normal turn.
        // Older sentNext receipts have a separate user row and still stay out of model history.
        row.metadata[SteerKey.steer] = nil
        conversation.messages.removeAll { $0 === row }
        let index = conversation.messages.firstIndex { $0.metadata[TurnWaitCopy.key] == "waiting" }
        conversation.messages.insert(row, at: index ?? conversation.messages.endIndex)
    }

    /// The bots a queued entry would start a turn for (its chat's owner, or the group members it names).
    private func waitingBots(_ next: QueuedNextMessage) -> [Bot] {
        guard let group = next.conversation as? GroupChat else { return (next.conversation as? Bot).map { [$0] } ?? [] }
        let ids = queuedRecipients(next.bubble, in: group)
        return ids.compactMap { id in bots.first { $0.id == id } }
    }

    private func queuedRecipients(_ bubble: ChatMessage, in group: GroupChat) -> [UUID] {
        let members = routingMembers(of: group)
        if let pinned = bubble.metadata[TurnWaitCopy.recipients] {
            let parts = pinned.components(separatedBy: ",")
            let ids = parts.compactMap(UUID.init(uuidString:))
            guard parts.count == ids.count else { return [] }
            return ids.allSatisfy { id in members.contains { $0.id == id } } ? ids : []
        }
        if bubble.isSteer {
            // Legacy group steers lack a trustworthy recipient once membership changes.
            guard let id = bubble.replyToID, let author = group.messages.first(where: { $0.id == id })?.authorID,
                  members.contains(where: { $0.id == author }) else { return [] }
            return [author]
        }
        return GroupRouting.recipients(of: bubble.content, members: members)
    }

    // MARK: P39 turn limit

    /// The user's message is already in `conversation`; it waits there with one line until a turn may start.
    func waitForTurn(_ user: ChatMessage, in conversation: any Conversation, reason: String, startupTarget: StartupSteerTarget? = nil,
                     predecessor: QueuePredecessor = .conversation, keepOnFailure: Bool = false) -> Bool {
        user.metadata[TurnWaitCopy.key] = "waiting"
        var next = QueuedNextMessage(conversation: conversation, bubble: user, kind: .turn, predecessor: predecessor)
        next.startupTarget = startupTarget
        guard enqueueNextMessage(next) else {
            user.metadata[TurnWaitCopy.key] = nil
            if !keepOnFailure { conversation.messages.removeAll { $0 === user } }
            return false
        }
        if let index = conversation.messages.firstIndex(where: { $0 === user }) {
            conversation.messages.insert(ChatMessage(role: .system, content: reason, metadata: [TurnWaitCopy.key: "line"]), at: index + 1)
        }
        objectWillChange.send(); save()
        if turns.saveFailing {
            turns.nextMessages.removeAll { $0.id == next.id }
            endWait(user, in: conversation)
            if !keepOnFailure { conversation.messages.removeAll { $0 === user } }
            recordNextMessage(next, .removed)
            return false
        }
        draftReplyIDs[conversation.id] = nil
        return true
    }

    func hasWaitingTurn(in conversation: any Conversation) -> Bool { turns.nextMessages.contains { $0.conversation === conversation } }

    /// The message leaves the wait: its marker and the "Waiting" line go.
    func endWait(_ user: ChatMessage, in conversation: any Conversation) {
        user.metadata[TurnWaitCopy.key] = nil
        if let index = conversation.messages.firstIndex(where: { $0 === user }), index + 1 < conversation.messages.endIndex,
           conversation.messages[index + 1].metadata[TurnWaitCopy.key] == "line" { conversation.messages.remove(at: index + 1) }
    }
}

/// P39 6: the line under a message that waits for a free turn.
enum TurnWaitCopy {
    static let recipients = "queuedRecipientIDs"
    static let key = "turnWait"
    static let promptServer = "waitingAtPromptServer"
    static let atPrompt = "Queued until the terminal is ready."
    static let afterAnswer = "Queued as the next message after this answer."
    static let cancelled = "Queued send cancelled. You can send this message again."
    static let behind = "Waiting: an earlier message in this chat goes first."
    static let predecessorNotConfirmed = "Not sent because the preceding message could not be confirmed. You can send this message again."
    static let notSent = "Not sent: it was still waiting for a free turn."
}
