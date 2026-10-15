import Foundation

/// A failed steer's text (or a review's notes) waiting for the running turn to end. P38 E: kept in the run ledger too
/// (`AppStore+QueueRecovery.swift`); `restored` entries came back from a quit and wait for the launch reconcile.
struct QueuedNextMessage {
    var id = UUID()
    let conversation: any Conversation
    let bubble: ChatMessage
    var kind: NextMessageRecord.Kind = .steer
    var anchorID: UUID
    var restored = false
    init(id: UUID = UUID(), conversation: any Conversation, bubble: ChatMessage, kind: NextMessageRecord.Kind = .steer, anchorID: UUID? = nil, restored: Bool = false) {
        self.id = id; self.conversation = conversation; self.bubble = bubble; self.kind = kind; self.anchorID = anchorID ?? bubble.id; self.restored = restored
    }
}

/// P32 item 9: a steer that was not delivered ("failed") offers "Send as next message". Its text goes out as a normal
/// message in the same chat, thread or group: at once when nothing runs, else once the running turn or round ends.
/// The failed bubble stays where it was and says what happened to it.
extension AppStore {
    /// Shown under a failed steer bubble that is not already waiting (a "next" left over from a quit counts as failed).
    func canSendAsNextMessage(_ bubble: ChatMessage) -> Bool {
        guard bubble.role == .user, let state = bubble.metadata[SteerKey.steer] else { return false }
        let waiting = turns.nextMessages.contains { $0.bubble === bubble }
        return (state == "failed" || state == "next" && !waiting) && conversation(containing: bubble.id) != nil
    }

    /// "Send as next message" pressed. False when the bubble is not a failed steer or its chat can't send.
    @discardableResult func sendAsNextMessage(_ bubble: ChatMessage) -> Bool {
        guard canSendAsNextMessage(bubble), let conversation = conversation(containing: bubble.id) else { return false }
        bubble.metadata[SteerKey.steer] = "next"
        guard enqueueNextMessage(QueuedNextMessage(conversation: conversation, bubble: bubble)) else { bubble.metadata[SteerKey.steer] = "failed"; return false }
        objectWillChange.send(); save()
        sendQueuedNextMessage()
        return true
    }

    /// Sends the oldest waiting text when no turn runs; called again whenever a turn or round ends. A chat that can no
    /// longer send puts its bubble back to "failed" (the button returns) and the next one is tried.
    /// P38 D: workflow replies that ended are settled first; the next workflow task goes only after the user's own.
    /// P38 E: an entry is marked sent in the ledger before it goes (a refused write keeps it queued); entries restored
    /// after a quit wait for `resumeRestoredNextMessages`.
    /// P39: per chat. Each chat's oldest entry goes once that chat has no turn and the turn limits allow it; a chat's later
    /// entries wait behind its first, and a restored entry holds its own chat only.
    func sendQueuedNextMessage() {
        settleWorkflows()
        var held: Set<UUID> = []; var index = 0
        while index < turns.nextMessages.count {
            let next = turns.nextMessages[index], key = next.conversation.id
            guard !held.contains(key), !next.restored, isIdle(next.conversation), turnCapacityProblem(for: waitingBots(next)) == nil else {
                held.insert(key); index += 1; continue
            }
            guard recordNextMessage(next, .sent) else { break }
            turns.nextMessages.remove(at: index)
            if startNextMessage(next) {
                if next.kind != .turn { next.bubble.metadata[SteerKey.steer] = "sentNext" }
                held.insert(key); objectWillChange.send(); save(); continue
            }
            recordNextMessage(next, .removed)
            if next.kind == .turn { giveBackBubble(next) } else { next.bubble.metadata[SteerKey.steer] = "failed" }
            objectWillChange.send(); save()
        }
        dispatchWorkflows()
    }

    private func startNextMessage(_ next: QueuedNextMessage) -> Bool {
        let text = next.bubble.content
        if let group = next.conversation as? GroupChat {
            guard groups.contains(where: { $0 === group }) else { return false }
            guard next.kind == .turn else { return send(text: text, to: group) }
            endWait(next.bubble, in: group)
            return startGroupRound(group, message: next.bubble, recipients: GroupRouting.recipients(of: text, members: routingMembers(of: group)))
        }
        guard let bot = owner(of: next.conversation), bots.contains(where: { $0 === bot }), !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly,
              !needsKey(bot), openClawBlock(bot) == nil, let activeBackend = try? backend(for: bot) else { return false }
        let user: ChatMessage
        if next.kind == .turn {
            user = next.bubble; endWait(user, in: next.conversation)
        } else {
            user = ChatMessage(role: .user, content: text); next.conversation.messages.append(user)
        }
        let images = (try? user.attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:))) ?? []
        startChatTurn(bot: bot, conversation: next.conversation, user: user, images: images, backend: activeBackend)
        return true
    }

    /// The bots a queued entry would start a turn for (its chat's owner, or the group members it names).
    private func waitingBots(_ next: QueuedNextMessage) -> [Bot] {
        guard let group = next.conversation as? GroupChat else { return owner(of: next.conversation).map { [$0] } ?? [] }
        let ids = GroupRouting.recipients(of: next.bubble.content, members: routingMembers(of: group))
        return ids.compactMap { id in bots.first { $0.id == id } }
    }

    // MARK: P39 turn limit

    /// The user's message is already in `conversation`; it waits there with one line until a turn may start.
    func waitForTurn(_ user: ChatMessage, in conversation: any Conversation, reason: String) -> Bool {
        user.metadata[TurnWaitCopy.key] = "waiting"
        let next = QueuedNextMessage(conversation: conversation, bubble: user, kind: .turn)
        guard enqueueNextMessage(next) else { user.metadata[TurnWaitCopy.key] = nil; conversation.messages.removeAll { $0 === user }; return false }
        if let index = conversation.messages.firstIndex(where: { $0 === user }) {
            conversation.messages.insert(ChatMessage(role: .system, content: reason, metadata: [TurnWaitCopy.key: "line"]), at: index + 1)
        }
        replyTo = nil; objectWillChange.send(); save()
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
    static let key = "turnWait"
    static let behind = "Waiting: an earlier message in this chat goes first."
    static let notSent = "Not sent: it was still waiting for a free turn."
}
