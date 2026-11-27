import Foundation

/// A user ID survives a Retry, a split reply, and a prompt refusal that replaces the reply placeholder.
enum QueuePredecessor: Codable, Equatable, Sendable {
    case message(UUID), independent, unknown
    /// Existing recovery rules for explicit steers, group rounds and other queue clients.
    case conversation
}

enum QueuePredecessorResolution { case ready, waiting, giveBack }

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
    var predecessor: QueuePredecessor?
    /// Reapply the local give-back if the app quit between the journal commit and the chat save.
    var returnWarning: String?
}

/// P38 E (Codex's queued turns that survive a restart, on main's design): what waited as the next message resumes in
/// order on reopen. Direct turns wait for their own predecessor after launch reconciliation. An explicit steer
/// still goes back to the user if its chat has an unconfirmed reply.
extension AppStore {
    static let nextMessageKind = "nextMessage"

    /// Writes one entry's state; false (and the reason shown) when the ledger refused it. A window that does not save keeps
    /// the queue in memory only.
    @discardableResult func recordNextMessage(_ next: QueuedNextMessage, _ state: NextMessageRecord.State) -> Bool {
        guard persistenceEnabled else { return true }
        do {
            try journal().put(NextMessageRecord(id: next.id, anchorID: next.anchorID, kind: next.kind, text: next.bubble.content, state: state, predecessor: next.predecessor),
                              kind: Self.nextMessageKind, id: next.id.uuidString)
            return true
        } catch { errorMessage = "Could not save the message queue: \(error.localizedDescription)"; return false }
    }

    /// Joins the queue only once the ledger has it.
    func enqueueNextMessage(_ next: QueuedNextMessage) -> Bool {
        guard recordNextMessage(next, .waiting) else { return false }
        insertNextMessage(next); return true
    }

    private func insertNextMessage(_ next: QueuedNextMessage) {
        let rows = next.conversation.messages
        if let index = rows.firstIndex(where: { $0 === next.bubble }),
           let later = turns.nextMessages.firstIndex(where: { item in
               item.conversation === next.conversation && rows[(index + 1)...].contains(where: { $0 === item.bubble })
           }) {
            turns.nextMessages.insert(next, at: later)
        } else {
            turns.nextMessages.append(next)
        }
    }

    /// Launch (`restoreLedger`): waiting entries rejoin the queue in their order, held until the launch reconcile ran.
    func restoreNextMessages() {
        guard persistenceEnabled, hasLedger else { return }
        do {
            let records = try journal().records(NextMessageRecord.self, kind: Self.nextMessageKind)
            if records.contains(where: { $0.returnWarning != nil }) {
                let latest = Dictionary(records.map { ($0.anchorID, $0) }, uniquingKeysWith: { _, newer in newer })
                for bot in bots {
                    for bubble in bot.messages where bubble.metadata[TurnWaitCopy.key] == "waiting" {
                        guard let record = latest[bubble.id], record.state == .removed, let warning = record.returnWarning,
                              !bot.messages.contains(where: { $0.role == .assistant && $0.metadata[TurnKey.forUser] == bubble.id.uuidString })
                        else { continue }
                        giveBackBubble(QueuedNextMessage(id: record.id, conversation: bot, bubble: bubble, kind: .turn,
                                                         predecessor: record.predecessor ?? .unknown), warning: warning)
                        save()
                    }
                }
            }
            for record in records where record.state == .waiting || record.state == .submitting || record.state == .uncertain {
                guard !turns.nextMessages.contains(where: { $0.id == record.id }) else { continue }
                guard let conversation = conversation(containing: record.anchorID), let anchor = conversation.messages.first(where: { $0.id == record.anchorID }) else {
                    try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                }
                if record.state == .submitting || record.state == .uncertain {
                    let ownsReply = conversation.messages.contains { $0.role == .assistant && $0.metadata[TurnKey.forUser] == anchor.id.uuidString }
                    var changed = anchor.metadata[TurnWaitCopy.key] == "waiting"
                    if changed { endWait(anchor, in: conversation) }
                    // A saved reply owns its Retry or receipt. A submitted queue record alone proves neither outcome.
                    if !ownsReply, !["delivered", "failed", "uncertain"].contains(anchor.metadata[SteerKey.steer] ?? "") {
                        anchor.metadata[SteerKey.steer] = "uncertain"
                        changed = true
                    }
                    let warning = ReconcileNote.uncertainQueuePrefix + record.text
                    if !conversation.messages.contains(where: { $0.role == .system && $0.content == warning }) {
                        conversation.messages.append(ReconcileNote.line(warning))
                        changed = true
                    }
                    if changed { save() }
                    if record.state == .submitting {
                        try journal().put(with(record, state: .uncertain), kind: Self.nextMessageKind, id: record.id.uuidString)
                    }
                    continue
                }
                let index = conversation.messages.firstIndex { $0 === anchor }
                let legacyWait = index.flatMap { conversation.messages.indices.contains($0 + 1) ? conversation.messages[$0 + 1] : nil }
                if record.kind == .steer && anchor.metadata[SteerKey.explicitNext] != "1" ||
                    record.kind == .turn && legacyWait?.metadata[TurnWaitCopy.key] == "line" && legacyWait?.content == SteerCopy.afterTurn {
                    endWait(anchor, in: conversation)
                    anchor.metadata[SteerKey.steer] = "failed"
                    try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString)
                    save()
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
                        if anchor.metadata[TurnWaitCopy.key] == "waiting" {
                            endWait(anchor, in: conversation)
                            addWarning("The queued message changed before it could be sent.", in: conversation, after: anchor)
                            save()
                        }
                        try journal().put(with(record, state: .removed), kind: Self.nextMessageKind, id: record.id.uuidString); continue
                    }
                    bubble = anchor
                }
                // Older direct sends lack the link. A nearby finished reply cannot identify their predecessor.
                let directSend = record.kind == .turn && tracksPredecessor(of: bubble, in: conversation)
                let predecessor = record.predecessor ?? (directSend ? .unknown : .conversation)
                insertNextMessage(QueuedNextMessage(id: record.id, conversation: conversation, bubble: bubble, kind: record.kind,
                                                    anchorID: anchor.id, predecessor: predecessor, restored: true))
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
            for row in conversation.messages where ["sent", "queued"].contains(row.metadata[SteerKey.steer] ?? "") {
                guard !turns.inFlightSteers.contains(row.id), !steerHeldByTurn(row) else { continue }
                row.metadata[SteerKey.steer] = "uncertain"
                changed = true
            }
        }
        guard changed else { return }
        let preserveRestoreUndo = restoreUndoRevision != nil && restoreUndoRevision == storeRevision
        objectWillChange.send()
        save()
        if preserveRestoreUndo, !turns.saveFailing, let storeRevision { rememberRestoreUndo(storeRevision) }
    }

    /// Drop the launch barrier. The drain checks each direct predecessor again at dispatch time.
    func resumeRestoredNextMessages() {
        var kept: [QueuedNextMessage] = []
        for var next in turns.nextMessages {
            guard next.restored else { kept.append(next); continue }
            if next.predecessor == .conversation, let reply = unconfirmedReply(in: next.conversation) {
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

    func tracksPredecessor(of user: ChatMessage, in conversation: any Conversation) -> Bool {
        conversation is Bot && user.metadata[HerdrBotRelay.Key.kind] == nil && user.metadata[GoalKey.attempt] == nil
    }

    /// Called when appending an ordinary direct send. A capacity wait in an idle chat has no local predecessor.
    func predecessorForSend(_ user: ChatMessage, in conversation: any Conversation) -> QueuePredecessor {
        guard tracksPredecessor(of: user, in: conversation) else { return .conversation }
        if let previous = turns.nextMessages.last(where: { $0.conversation === conversation }) {
            return .message(previous.bubble.id)
        }
        guard let active = turn(in: conversation) else { return .independent }
        guard let id = active.assistant?.metadata[TurnKey.forUser].flatMap(UUID.init(uuidString:)) else { return .unknown }
        return .message(id)
    }

    func resolvePredecessor(for next: QueuedNextMessage, removing removed: Set<UUID> = []) -> QueuePredecessorResolution {
        switch next.predecessor {
        case .independent, .conversation: return .ready
        case .unknown: return .giveBack
        case .message(let id):
            let rows = next.conversation.messages
            guard let user = rows.first(where: { $0.id == id && $0.role == .user }) else { return .giveBack }
            // Only an earlier queue entry can still run before this one.
            if turns.nextMessages.prefix(while: { $0.id != next.id }).contains(where: { $0.bubble === user && !removed.contains($0.id) }) ||
                turns.inFlightSteers.contains(id) { return .waiting }
            let replies: [ChatMessage]
            if user.isSteer {
                guard user.metadata[SteerKey.steer] == "delivered", let origin = user.metadata[TurnReplyText.origin] else { return .giveBack }
                replies = rows.filter { $0.role == .assistant && ($0.id.uuidString == origin || $0.metadata[TurnReplyText.origin] == origin) }
            } else {
                replies = rows.filter { $0.role == .assistant && $0.metadata[TurnKey.forUser] == id.uuidString }
            }
            guard let last = replies.last else { return .giveBack }
            let origin = last.metadata[TurnReplyText.origin] ?? last.id.uuidString
            guard replies.dropLast().allSatisfy({ ($0.metadata[TurnReplyText.origin] ?? $0.id.uuidString) == origin &&
                !$0.isStreaming && $0.turnState == .finished }) else { return .giveBack }
            if turn(in: next.conversation)?.assistant === last { return .waiting }
            if !last.isStreaming, last.turnState == .finished || (last.turnState == .stopped && last.metadata[TurnKey.why] == "stopped") {
                return .ready
            }
            if canRetry(last) { return .waiting }
            if let bot = next.conversation as? Bot, canRecoverSavedReply(last, in: bot) { return .waiting }
            return .giveBack
        }
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
    func giveBackBubble(_ next: QueuedNextMessage, warning: String = TurnWaitCopy.notSent) {
        switch next.kind {
        case .steer: next.bubble.metadata[SteerKey.steer] = "failed"
        case .reviewNotes: break
        case .turn:
            // The explicit resend action keeps this text available and out of subsequent model history.
            if next.predecessor != .conversation { next.bubble.metadata[SteerKey.steer] = "failed" }
            next.bubble.metadata[TurnWaitCopy.promptServer] = nil
            endWait(next.bubble, in: next.conversation)
            addWarning(warning, in: next.conversation, after: next.bubble)
        }
    }
}
