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
    func sendQueuedNextMessage() {
        settleWorkflows()
        while isIdle, !isStreaming, let next = turns.nextMessages.first, !next.restored {
            guard recordNextMessage(next, .sent) else { break }
            turns.nextMessages.removeFirst()
            if startNextMessage(next) { next.bubble.metadata[SteerKey.steer] = "sentNext"; objectWillChange.send(); save(); return }
            recordNextMessage(next, .removed)
            next.bubble.metadata[SteerKey.steer] = "failed"; objectWillChange.send(); save()
        }
        dispatchWorkflows()
    }

    private func startNextMessage(_ next: QueuedNextMessage) -> Bool {
        let text = next.bubble.content
        if let group = next.conversation as? GroupChat {
            guard groups.contains(where: { $0 === group }) else { return false }
            return send(text: text, to: group)
        }
        guard let bot = owner(of: next.conversation), bots.contains(where: { $0 === bot }), !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly,
              !needsKey(bot), openClawBlock(bot) == nil, let activeBackend = try? backend(for: bot) else { return false }
        let user = ChatMessage(role: .user, content: text)
        next.conversation.messages.append(user)
        startChatTurn(bot: bot, conversation: next.conversation, user: user, backend: activeBackend)
        return true
    }
}
