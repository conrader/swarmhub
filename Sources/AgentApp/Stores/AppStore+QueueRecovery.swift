import Foundation

/// P38 E: one queued next message in the run ledger (kind `nextMessage`), written before it joins the queue and again
/// before it is sent, so a quit never loses or repeats it. `anchorID` is the row that offered it: the failed steer
/// bubble, or the review card whose notes go out.
struct NextMessageRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case steer, reviewNotes }
    enum State: String, Codable, Sendable { case waiting, sent, removed }
    var id: UUID
    var anchorID: UUID
    var kind: Kind
    var text: String
    var state: State
}

/// P38 E (Codex's queued turns that survive a restart, on main's design): what waited as the next message resumes in
/// order on reopen. It waits for the launch reconcile (`resumeRestoredNextMessages`); one whose chat still has an
/// unconfirmed reply, or whose text changed, goes back to the user (its button returns) instead of being sent. Rounds,
/// Retry and Refresh stay P16's: a group's finished member replies are kept and the members a quit skipped offer Retry.
extension AppStore {
    static let nextMessageKind = "nextMessage"

    /// Writes one entry's state; false (and the reason shown) when the ledger refused it. A window that does not save keeps
    /// the queue in memory only.
    @discardableResult func recordNextMessage(_ next: QueuedNextMessage, _ state: NextMessageRecord.State) -> Bool {
        guard persistenceEnabled else { return true }
        do {
            try journal().put(NextMessageRecord(id: next.id, anchorID: next.anchorID, kind: next.kind, text: next.bubble.content, state: state),
                              kind: Self.nextMessageKind, id: next.id.uuidString)
            return true
        } catch { errorMessage = "Could not save the message queue: \(error.localizedDescription)"; return false }
    }

    /// Joins the queue only once the ledger has it.
    func enqueueNextMessage(_ next: QueuedNextMessage) -> Bool {
        guard recordNextMessage(next, .waiting) else { return false }
        turns.nextMessages.append(next); return true
    }

    /// Launch (`restoreLedger`): waiting entries rejoin the queue in their order, held until the launch reconcile ran.
    func restoreNextMessages() {
        guard persistenceEnabled, hasLedger else { return }
        do {
            for record in try journal().records(NextMessageRecord.self, kind: Self.nextMessageKind) where record.state == .waiting {
                guard !turns.nextMessages.contains(where: { $0.id == record.id }) else { continue }
                guard let conversation = conversation(containing: record.anchorID), let anchor = conversation.messages.first(where: { $0.id == record.anchorID }) else {
                    try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                }
                let bubble: ChatMessage
                switch record.kind {
                case .steer:
                    guard anchor.metadata[SteerKey.steer] == "next", anchor.content == record.text else {
                        if anchor.metadata[SteerKey.steer] == "next" { anchor.metadata[SteerKey.steer] = "failed" }
                        try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                    }
                    bubble = anchor
                case .reviewNotes:
                    guard anchor.metadata[ReviewKey.sent] == "1", reviewNotesText(anchor) == record.text else {
                        anchor.metadata[ReviewKey.sent] = nil
                        try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                    }
                    bubble = ChatMessage(role: .user, content: record.text)
                }
                turns.nextMessages.append(QueuedNextMessage(id: record.id, conversation: conversation, bubble: bubble, kind: record.kind, anchorID: anchor.id, restored: true))
            }
        } catch { errorMessage = "Could not restore the message queue: \(error.localizedDescription)" }
    }

    private func with(_ record: NextMessageRecord, state: NextMessageRecord.State) -> NextMessageRecord {
        var copy = record; copy.state = state; return copy
    }

    /// After the launch reconcile: restored entries whose chat has no unconfirmed reply are released in order; the others
    /// go back to the user with a line saying why. Then the queue is sent.
    func resumeRestoredNextMessages() {
        var kept: [QueuedNextMessage] = []
        for var next in turns.nextMessages {
            guard next.restored else { kept.append(next); continue }
            if let reply = unconfirmedReply(in: next.conversation) {
                giveBack(next)
                addWarning("A queued message was not sent after the restart: an earlier reply is not confirmed yet. Refresh that reply, then send the message again.",
                           in: next.conversation, after: reply)
                continue
            }
            next.restored = false; kept.append(next)
        }
        turns.nextMessages = kept
        objectWillChange.send(); save()
        sendQueuedNextMessage()
    }

    /// An `incomplete` reply, or a not-sent one the box may have.
    func unconfirmedReply(in conversation: any Conversation) -> ChatMessage? {
        conversation.messages.last { $0.role == .assistant && !$0.isStreaming && ($0.turnState == .incomplete || ($0.turnState == .notSent && $0.metadata[TurnKey.ambiguous] == "1")) }
    }

    /// The entry leaves the queue; its button (Send as next message, Send notes) offers it again.
    func giveBack(_ next: QueuedNextMessage) {
        recordNextMessage(next, .removed)
        switch next.kind {
        case .steer: next.bubble.metadata[SteerKey.steer] = "failed"
        case .reviewNotes: conversation(containing: next.anchorID)?.messages.first { $0.id == next.anchorID }?.metadata[ReviewKey.sent] = nil
        }
    }
}
