import Foundation

/// P38 E: one queued next message in the run ledger (kind `nextMessage`), written before it joins the queue and again
/// before it is sent, so interrupted dispatch can be surfaced without blind replay. `anchorID` is the row that offered it: the failed steer
/// bubble, or the review card whose notes go out.
struct NextMessageRecord: Codable, Equatable, Sendable {
    /// `turn`: a user message that waits at the turn limit; the anchor is the message itself. `reviewNotes` is what an
    /// older build queued for a feature this build does not have: such a record is read and dropped.
    enum Kind: String, Codable, Sendable { case steer, reviewNotes, turn }
    enum State: String, Codable, Sendable { case waiting, submitting, uncertain, sent, removed }
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
            for record in try journal().records(NextMessageRecord.self, kind: Self.nextMessageKind) where record.state == .waiting || record.state == .submitting || record.state == .uncertain {
                guard !turns.nextMessages.contains(where: { $0.id == record.id }) else { continue }
                guard let conversation = conversation(containing: record.anchorID), let anchor = conversation.messages.first(where: { $0.id == record.anchorID }) else {
                    try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                }
                if record.state == .submitting || record.state == .uncertain {
                    let warning = ReconcileNote.uncertainQueuePrefix + record.text
                    if !conversation.messages.contains(where: { $0.content == warning }) {
                        conversation.messages.append(ReconcileNote.line(warning))
                    }
                    // Retain the text and operation ID durably; never silently replay an uncertain send.
                    try journal().put(with(record, state: .uncertain), kind: Self.nextMessageKind, id: record.id.uuidString)
                    continue
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
                    try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                case .turn:
                    guard anchor.metadata[TurnWaitCopy.key] == "waiting", anchor.content == record.text else {
                        endWait(anchor, in: conversation)
                        try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                    }
                    bubble = anchor
                }
                turns.nextMessages.append(QueuedNextMessage(id: record.id, conversation: conversation, bubble: bubble, kind: record.kind, anchorID: anchor.id, restored: true))
            }
        } catch { errorMessage = "Could not restore the message queue: \(error.localizedDescription)" }
    }

    private func with(_ record: NextMessageRecord, state: NextMessageRecord.State) -> NextMessageRecord {
        var copy = record; copy.state = state; return copy
    }

    /// Older stores can retain steer bubbles after their turn disappears. The assistant row is inserted
    /// before the steers, and a split reply can continue below them, so consider the final part of that turn.
    func reconcileOrphanedSteers() {
        var changed = false
        let conversations: [any Conversation] = bots.map { $0 as any Conversation } + groups.map { $0 as any Conversation }
        for conversation in conversations {
            var reply: ChatMessage?
            var hasReplyContent = false
            var queued: [ChatMessage] = []

            func settleQueued() {
                guard !queued.isEmpty else { return }
                let state = reply?.turnState == .finished && hasReplyContent ? "delivered" : "failed"
                for bubble in queued { bubble.metadata[SteerKey.steer] = state }
                changed = true
                queued.removeAll()
            }

            for row in conversation.messages {
                switch row.role {
                case .assistant:
                    let part = row.metadata[TurnKey.part].flatMap(Int.init)
                    let previousPart = reply?.metadata[TurnKey.part].flatMap(Int.init)
                    let continuesReply = part.map { $0 > 1 && previousPart == $0 - 1 } == true
                        && reply?.authorID == row.authorID && reply?.metadata[TurnKey.forUser] == row.metadata[TurnKey.forUser]
                    if !continuesReply { settleQueued(); hasReplyContent = false }
                    reply = row
                    hasReplyContent = hasReplyContent || !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || row.publishedResults?.items.isEmpty == false
                case .user:
                    switch row.metadata[SteerKey.steer] {
                    case "sent" where !turns.inFlightSteers.contains(row.id): row.metadata[SteerKey.steer] = "failed"; changed = true
                    case "queued" where !steerHeldByTurn(row): queued.append(row)
                    case nil where row.metadata[TurnWaitCopy.key] != "waiting":
                        settleQueued(); reply = nil; hasReplyContent = false
                    default: break
                    }
                case .system: break
                }
            }
            settleQueued()
        }
        guard changed else { return }
        let preserveRestoreUndo = restoreUndoRevision != nil && restoreUndoRevision == storeRevision
        objectWillChange.send()
        save()
        if preserveRestoreUndo, !turns.saveFailing, let storeRevision { rememberRestoreUndo(storeRevision) }
    }

    /// After the launch reconcile: restored entries whose chat has no unconfirmed reply are released in order; the others
    /// go back to the user with a line saying why. Then the queue is sent.
    func resumeRestoredNextMessages() {
        var kept: [QueuedNextMessage] = []
        for var next in turns.nextMessages {
            guard next.restored else { kept.append(next); continue }
            if let reply = unconfirmedReply(in: next.conversation) {
                giveBack(next)
                addWarning("A queued message was not sent after the restart: the reply before it did not finish. Send the message again.",
                           in: next.conversation, after: reply)
                continue
            }
            next.restored = false; kept.append(next)
        }
        turns.nextMessages = kept
        objectWillChange.send(); save()
        sendQueuedNextMessage()
    }

    /// An `incomplete` reply, or a not-sent one the server may have.
    func unconfirmedReply(in conversation: any Conversation) -> ChatMessage? {
        conversation.messages.last { $0.role == .assistant && !$0.isStreaming && ($0.turnState == .incomplete || ($0.turnState == .notSent && $0.metadata[TurnKey.ambiguous] == "1")) }
    }

    /// The entry leaves the queue; its button (Send as next message) offers it again.
    func giveBack(_ next: QueuedNextMessage) {
        recordNextMessage(next, .removed)
        giveBackBubble(next)
    }

    /// What a removed entry leaves behind: the steer's button returns, and a message that waited for a turn says it
    /// was not sent.
    func giveBackBubble(_ next: QueuedNextMessage) {
        switch next.kind {
        case .steer: next.bubble.metadata[SteerKey.steer] = "failed"
        case .reviewNotes: break
        case .turn:
            endWait(next.bubble, in: next.conversation)
            addWarning(TurnWaitCopy.notSent, in: next.conversation, after: next.bubble)
        }
    }
}
