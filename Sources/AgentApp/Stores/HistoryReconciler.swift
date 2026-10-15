import Foundation

/// P16 reconcile engine. Pure: local rows and box rows in, a plan out; no network, clock or SwiftUI. The box is the source
/// of truth for what it finished; the plan only extends, fills, settles and adds, never deletes or reorders.
enum HistoryReconciler {
    /// A value snapshot of one local row.
    struct LocalRow: Sendable, Equatable {
        var id: UUID; var role: MessageRole; var text: String; var isTextTurn: Bool; var authorID: UUID?
        var state: TurnState?; var metadata: [String: String]; var createdAt: Date; var isStreaming: Bool
        /// P43: the row already has its steps (a box fill then leaves them alone).
        var hasSteps = false

        init(id: UUID = UUID(), role: MessageRole, text: String, isTextTurn: Bool = true, authorID: UUID? = nil, state: TurnState? = nil, metadata: [String: String] = [:], createdAt: Date = .distantPast, isStreaming: Bool = false) {
            self.id = id; self.role = role; self.text = text; self.isTextTurn = isTextTurn; self.authorID = authorID
            self.state = state; self.metadata = metadata; self.createdAt = createdAt; self.isStreaming = isStreaming
        }
        @MainActor init(_ message: ChatMessage) {
            self.init(id: message.id, role: message.role, text: message.role == .user ? message.outgoingText : message.content,
                      isTextTurn: message.presentation == .text && !message.isSteer, authorID: message.authorID, state: message.turnState,
                      metadata: message.metadata, createdAt: message.createdAt, isStreaming: message.isStreaming)
            hasSteps = (message.activity?.total ?? 0) > 0
        }
        var boxIDs: Set<Int> { Set((metadata[TurnKey.box] ?? "").split(separator: ",").compactMap { Int($0) }) }
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    enum Mode: Sendable, Equatable {
        /// A bot chat (`additions`: true) or a thread (extend and fill only).
        case chat(additions: Bool)
        /// One member of a group; `names` are every author name a blob may carry, `user` the label of the user's lines (P21 D6).
        case group(member: UUID, names: [String], user: String = GroupRouting.defaultUserName)
    }

    struct Input: Sendable {
        var local: [LocalRow]; var server: [BackendMessage]; var mode: Mode
        /// The Mac's clock now, and the box's clock minus the Mac's (from the GET's `Date` header).
        var now: Date = .now; var skew: TimeInterval = 0
        /// Box time of the oldest row read; nil = the whole session was read.
        var coversFrom: Date? = nil
        /// Rows whose run the box still reports active (queued, running, waiting_for_approval, stopping).
        var activeRuns: Set<UUID> = []
        var maxMidAdditions = 10; var notSentAge: TimeInterval = 120
    }

    struct Counts: Sendable, Equatable {
        var paired = 0, extended = 0, extendedChars = 0, filled = 0, added = 0, settled = 0
        var conflicts = 0, serverPrefix = 0, ambiguous = 0, ignoredOld = 0, capped = 0, notSent = 0
        static func + (a: Counts, b: Counts) -> Counts {
            .init(paired: a.paired + b.paired, extended: a.extended + b.extended, extendedChars: a.extendedChars + b.extendedChars, filled: a.filled + b.filled,
                  added: a.added + b.added, settled: a.settled + b.settled, conflicts: a.conflicts + b.conflicts, serverPrefix: a.serverPrefix + b.serverPrefix,
                  ambiguous: a.ambiguous + b.ambiguous, ignoredOld: a.ignoredOld + b.ignoredOld, capped: a.capped + b.capped, notSent: a.notSent + b.notSent)
        }
    }

    /// A change to an existing row: new full content (nil = unchanged), new state, metadata updates (nil value = remove).
    /// P43: `activity` = the box's steps for a row that had none, placed in its new text.
    struct Edit: Sendable, Equatable { var rowID: UUID; var content: String?; var state: TurnState?; var metadata: [String: String?] = [:]; var activity: ToolActivity? = nil }
    struct NewRow: Sendable, Equatable { var role: MessageRole; var content: String; var authorID: UUID?; var state: TurnState?; var metadata: [String: String]; var createdAt: Date; var activity: ToolActivity? = nil }
    /// Rows to insert after `after` (nil = at the end), in order.
    struct Addition: Sendable, Equatable { var after: UUID?; var rows: [NewRow] }

    struct Plan: Sendable, Equatable {
        var edits: [Edit] = []; var additions: [Addition] = []; var counts = Counts()
        /// Local turns exist, the box has rows and nothing pairs: nothing is changed (the quiet note appears for bot chats).
        var diverged = false
        /// Rows to keep polling (their run is active).
        var keepPolling: Set<UUID> = []
        /// An unpaired box turn is newer than the last paired one (Retry must not send by itself then).
        var newerUnmatched = false
        var isEmpty: Bool { edits.isEmpty && additions.isEmpty }
    }

    enum Relation: Equatable { case equal, localPrefix, serverPrefix, conflict }

    struct ServerTurn: Sendable {
        var index: Int; var user: BackendMessage?; var replies: [BackendMessage]
        /// P43: every assistant row of the turn in order, the ones with only tool calls included.
        var rows: [BackendMessage] = []
        var replyText: String { replies.map(\.content).joined(separator: "\n\n") }
        var ids: [Int] { ([user] + replies.map { $0 }).compactMap { $0?.id } }
        var time: Date? { user?.createdAt ?? replies.first?.createdAt }
        var attested: Bool { replies.last.map { ["stop", "end_turn", "length"].contains($0.finishReason ?? "") } ?? false }
        var endedWithError: Bool { ["error", "agent_error", "content_filter"].contains(replies.last?.finishReason ?? "") }
    }

    struct LocalTurn { var position: Int; var user: LocalRow?; var reply: LocalRow? }

    // MARK: Text

    static func squeezed(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })) }
    static func nonSpaceCount(_ text: String) -> Int { text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count }

    /// Reply relation with whitespace ignored.
    static func relation(local: String, server: String) -> Relation {
        let left = squeezed(local), right = squeezed(server)
        if left == right { return .equal }
        if right.hasPrefix(left) { return .localPrefix }
        if left.hasPrefix(right) { return .serverPrefix }
        return .conflict
    }

    /// The local text followed by the server's text after the matched prefix, minus the leading whitespace the local
    /// text already ends with. The old text stays a byte-for-byte prefix.
    static func extend(_ local: String, with server: String) -> String {
        let need = nonSpaceCount(local); let scalars = server.unicodeScalars
        var index = scalars.startIndex; var seen = 0
        while seen < need, index < scalars.endIndex {
            if !CharacterSet.whitespacesAndNewlines.contains(scalars[index]) { seen += 1 }
            index = scalars.index(after: index)
        }
        var rest = String(scalars[index...])
        let trailing = String(local.reversed().prefix { $0.isWhitespace }.reversed())
        if !trailing.isEmpty {
            let leading = String(rest.prefix { $0.isWhitespace })
            rest.removeFirst(leading.hasPrefix(trailing) ? trailing.count : leading.count)
        }
        return local + rest
    }

    // MARK: Turns

    static func serverTurns(_ rows: [BackendMessage]) -> [ServerTurn] {
        var turns: [ServerTurn] = []
        for row in rows {
            if row.role == "user" { turns.append(.init(index: turns.count, user: row, replies: [])) }
            else if row.role == "assistant", !turns.isEmpty {
                let hasText = !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasText { turns[turns.count - 1].replies.append(row) }
                if hasText || !row.tools.isEmpty { turns[turns.count - 1].rows.append(row) }
            }
        }
        return turns
    }

    static func localTurns(_ local: [LocalRow], mode: Mode) -> [LocalTurn] {
        let isUser: (LocalRow) -> Bool = { $0.role == .user && $0.isTextTurn }
        switch mode {
        case .chat:
            // P28 D5: a delivered steer followed by a reply part starts a turn of its own (the box keeps the steer as its own
            // user row); older steer bubbles, which no part follows, stay outside the turns.
            func startsPart(_ position: Int) -> Bool {
                local[position].role == .user && local[position].metadata[SteerKey.steer] == "delivered"
                    && local[(position + 1)...].first { $0.role == .assistant }?.metadata[TurnKey.part] != nil
            }
            var turns: [LocalTurn] = []
            for (position, row) in local.enumerated() {
                if isUser(row) || startsPart(position) { turns.append(.init(position: position, user: row, reply: nil)) }
                else if row.role == .assistant, row.isTextTurn, row.authorID == nil, !turns.isEmpty, turns[turns.count - 1].reply == nil {
                    turns[turns.count - 1].reply = row
                }
            }
            return turns
        case .group(let member, _, _):
            return local.enumerated().compactMap { position, row in
                guard row.role == .assistant, row.isTextTurn, row.authorID == member else { return nil }
                let trigger = row.metadata[TurnKey.forUser].flatMap(UUID.init(uuidString:)).flatMap { id in local.first { $0.id == id } }
                    ?? local[..<position].last(where: isUser)
                return .init(position: position, user: trigger, reply: row)
            }
        }
    }

    static func entries(_ turn: ServerTurn, mode: Mode) -> [GroupRouting.ContextEntry] {
        guard case .group(_, let names, let user) = mode, let blob = turn.user?.content else { return [] }
        return GroupRouting.parseContext(blob, names: names, userName: user) ?? []
    }

    /// The trigger sits in the blob as a whole entry written by the user.
    static func blob(_ entries: [GroupRouting.ContextEntry], carries trigger: String, mode: Mode) -> Bool {
        let wanted = AppStore.comparable(trigger)
        guard case .group(_, _, let user) = mode else { return false }
        return !wanted.isEmpty && entries.contains { $0.author == user && AppStore.comparable($0.text) == wanted }
    }

    static func userMatches(_ turn: LocalTurn, _ server: ServerTurn, mode: Mode) -> Bool {
        guard let user = turn.user else { return false }
        switch mode {
        case .chat: return server.user.map { AppStore.sameText(user.text, $0.content) } ?? false
        case .group: return blob(entries(server, mode: mode), carries: user.text, mode: mode)
        }
    }

    // MARK: Plan

    static func plan(_ input: Input) -> Plan {
        var plan = Plan()
        let server = serverTurns(input.server)
        let local = localTurns(input.local, mode: input.mode)
        let hasLocalTurns = local.contains { !($0.user?.isEmpty ?? true) || !($0.reply?.isEmpty ?? true) }
        var pairs: [Int: Int] = [:] // local turn index → server turn index
        var used: Set<Int> = []

        // Pairing, newest local turn first; turns with a reply first, so an empty resend cannot take the box's turn.
        let order = local.indices.reversed()
        let withReply = order.filter { !(local[$0].reply?.isEmpty ?? true) }, rest = order.filter { local[$0].reply?.isEmpty ?? true }
        for index in withReply + rest {
            let turn = local[index]
            let candidates = server.filter { !used.contains($0.index) && userMatches(turn, $0, mode: input.mode) }
            guard !candidates.isEmpty else { continue }
            let compatible = candidates.filter { candidate in turn.reply.map { relation(local: $0.text, server: candidate.replyText) != .conflict } ?? true }
            let pick = (compatible.isEmpty ? candidates : compatible).max { $0.index < $1.index }!
            pairs[index] = pick.index; used.insert(pick.index)
        }
        // Group turns the user side cannot match (empty trigger, or a blob whose cap dropped it): by reply, in order.
        if case .group = input.mode {
            for index in order where pairs[index] == nil {
                let turn = local[index]
                guard let reply = turn.reply, nonSpaceCount(reply.text) >= 20 else { continue }
                let lower = pairs.filter { $0.key < index }.map(\.value).max() ?? -1, upper = pairs.filter { $0.key > index }.map(\.value).min() ?? Int.max
                let triggerEmpty = turn.user?.isEmpty ?? true
                let pick = server.filter { candidate in
                    !used.contains(candidate.index) && candidate.index > lower && candidate.index < upper && nonSpaceCount(candidate.replyText) >= 20
                        && (triggerEmpty || entries(candidate, mode: input.mode).contains { $0.author == nil })
                        && relation(local: reply.text, server: candidate.replyText) != .conflict
                }.max { $0.index < $1.index }
                if let pick { pairs[index] = pick.index; used.insert(pick.index) }
            }
        }

        if pairs.isEmpty && hasLocalTurns && !server.isEmpty { plan.diverged = true; plan.newerUnmatched = true; return plan }

        let boxClockNow = input.now.addingTimeInterval(input.skew)
        func covers(_ date: Date) -> Bool { input.coversFrom.map { $0 <= date.addingTimeInterval(input.skew) } ?? true }

        // Paired turns.
        for (index, serverIndex) in pairs.sorted(by: { $0.key < $1.key }) {
            let turn = local[index], box = server[serverIndex]
            plan.counts.paired += 1
            guard let reply = turn.reply else {
                // A bot-chat user row with no reply row: the box's reply is inserted after it.
                if case .chat(true) = input.mode, let user = turn.user, !box.replyText.isEmpty {
                    plan.additions.append(.init(after: user.id, rows: [newReply(box, author: nil, mode: input.mode)]))
                    plan.counts.added += 1
                }
                continue
            }
            if let edit = settle(reply, with: box, active: input.activeRuns.contains(reply.id), plan: &plan) { plan.edits.append(edit) }
        }

        // "Later": a member's notSent row whose trigger a later paired turn of that member carried.
        if case .group = input.mode {
            for (index, turn) in local.enumerated() where pairs[index] == nil {
                guard let reply = turn.reply, reply.state == .notSent, reply.isEmpty, let trigger = turn.user else { continue }
                let carried = pairs.contains { $0.key > index && blob(entries(server[$0.value], mode: input.mode), carries: trigger.text, mode: input.mode) }
                if carried {
                    plan.edits.append(.init(rowID: reply.id, content: nil, state: .finished, metadata: [TurnKey.why: "later", TurnKey.ambiguous: nil]))
                    plan.counts.settled += 1
                }
            }
        }

        // An empty placeholder the box never got, old enough and covered by the read, is not sent.
        for (index, turn) in local.enumerated() where pairs[index] == nil {
            guard let reply = turn.reply, reply.state == .incomplete, reply.isEmpty, !reply.isStreaming,
                  boxClockNow.timeIntervalSince(reply.createdAt.addingTimeInterval(input.skew)) > input.notSentAge, covers(reply.createdAt) else { continue }
            plan.edits.append(.init(rowID: reply.id, content: nil, state: .notSent, metadata: [:]))
            plan.counts.notSent += 1
        }

        // Unpaired box turns: newer than the oldest pair (or all, with no local turn) are added, guarded against duplicates.
        let additionsAllowed: Bool; if case .chat(false) = input.mode { additionsAllowed = false } else { additionsAllowed = true }
        let oldestPair = pairs.values.min(), newestPair = pairs.values.max()
        plan.newerUnmatched = server.contains { !used.contains($0.index) && $0.index > (newestPair ?? -1) }
        let knownIDs = input.local.reduce(into: Set<Int>()) { $0.formUnion($1.boxIDs) }
        var midAdded = 0
        for box in server where !used.contains(box.index) {
            if hasLocalTurns, let oldestPair, box.index < oldestPair { plan.counts.ignoredOld += 1; continue }
            if hasLocalTurns && oldestPair == nil { continue }
            guard additionsAllowed, !box.replyText.isEmpty || !isGroup(input.mode) else { continue }
            if !Set(box.ids).isDisjoint(with: knownIDs) { continue }
            if isDuplicate(box, local: input.local, mode: input.mode) { plan.counts.ambiguous += 1; continue }
            let localTime = box.time?.addingTimeInterval(-input.skew)
            let anchor = localTime.flatMap { time in input.local.last { $0.createdAt <= time } }
            let after = anchor?.id == input.local.last?.id ? nil : anchor?.id
            if after != nil {
                guard midAdded < input.maxMidAdditions else { plan.counts.capped += 1; continue }
                midAdded += 1
            }
            var rows: [NewRow] = []
            if case .chat = input.mode, let user = box.user {
                var metadata = [TurnKey.restored: "added", TurnKey.box: ids(user.id.map { [$0] } ?? [])]
                if user.outOfBand { metadata[SteerKey.outOfBand] = "1" }
                rows.append(.init(role: .user, content: user.content, authorID: nil, state: nil, metadata: metadata, createdAt: localTime ?? input.now))
            }
            if !box.replyText.isEmpty { rows.append(newReply(box, author: memberID(input.mode), mode: input.mode, time: localTime ?? input.now)) }
            // Turns sharing an anchor stay in box order.
            if let index = plan.additions.lastIndex(where: { $0.after == after }) { plan.additions[index].rows += rows }
            else { plan.additions.append(.init(after: after, rows: rows)) }
            plan.counts.added += 1
        }
        return plan
    }

    /// The outcome for one paired reply row. `finished` and `stopped` rows are never edited.
    static func settle(_ reply: LocalRow, with box: ServerTurn, active: Bool, plan: inout Plan) -> Edit? {
        guard !reply.isStreaming, reply.state != .finished, reply.state != .stopped else { return nil }
        let eligible = reply.state == .incomplete || reply.state == nil || (reply.state == .notSent && reply.isEmpty)
        guard eligible else { return nil }
        let boxIDs = ids(box.ids)
        let attested = box.attested && !active
        if active { plan.keepPolling.insert(reply.id) }
        switch relation(local: reply.text, server: box.replyText) {
        case .equal where box.replyText.isEmpty:
            // The box has the user turn but no reply yet.
            guard reply.state == .notSent else { return nil }
            return .init(rowID: reply.id, content: nil, state: .incomplete, metadata: [TurnKey.why: nil, TurnKey.ambiguous: nil, TurnKey.box: boxIDs])
        case .equal:
            guard reply.state != nil else { return nil }
            if attested {
                plan.counts.settled += 1
                return .init(rowID: reply.id, content: nil, state: .finished, metadata: [TurnKey.why: nil, TurnKey.ambiguous: nil, TurnKey.end: nil, TurnKey.box: boxIDs])
            }
            if active { return nil }
            let end = box.endedWithError ? "error" : "none"
            guard reply.metadata[TurnKey.end] != end || reply.state != .incomplete || reply.metadata[TurnKey.box] != boxIDs else { return nil }
            return .init(rowID: reply.id, content: nil, state: .incomplete, metadata: [TurnKey.end: end, TurnKey.box: boxIDs])
        case .localPrefix:
            let content = extend(reply.text, with: box.replyText)
            let steps = reply.hasSteps ? nil : box.activity.map { placed($0, from: box.replyText, in: content) }
            if reply.isEmpty { plan.counts.filled += 1 } else { plan.counts.extended += 1 }
            plan.counts.extendedChars += content.count - reply.text.count
            let end: String? = attested || active ? nil : (box.endedWithError ? "error" : "none")
            return .init(rowID: reply.id, content: content, state: attested ? .finished : .incomplete,
                         metadata: [TurnKey.restored: "extended", TurnKey.box: boxIDs, TurnKey.why: nil, TurnKey.ambiguous: nil, TurnKey.end: end], activity: steps)
        case .serverPrefix: plan.counts.serverPrefix += 1; return nil
        case .conflict: plan.counts.conflicts += 1; return nil
        }
    }

    static func newReply(_ box: ServerTurn, author: UUID?, mode: Mode, time: Date = .distantPast) -> NewRow {
        .init(role: .assistant, content: box.replyText, authorID: author, state: box.attested ? .finished : nil,
              metadata: [TurnKey.restored: "added", TurnKey.box: ids(box.replies.compactMap(\.id))], createdAt: max(time, box.replies.first?.createdAt ?? time),
              activity: box.activity)
    }

    /// Never add a box turn whose reply (or, in a chat, user text) is equal or prefix-related to a local row.
    static func isDuplicate(_ box: ServerTurn, local: [LocalRow], mode: Mode) -> Bool {
        func related(_ a: String, _ b: String) -> Bool {
            guard !squeezed(a).isEmpty, !squeezed(b).isEmpty else { return false }
            return relation(local: a, server: b) != .conflict
        }
        let member = memberID(mode)
        let replies = local.filter { $0.role == .assistant && $0.authorID == member }
        if replies.contains(where: { related($0.text, box.replyText) }) { return true }
        if case .chat = mode, let user = box.user {
            let text = AppStore.comparable(user.content)
            return local.contains { $0.role == .user && related(AppStore.comparable($0.text), text) }
        }
        return false
    }

    static func ids(_ values: [Int]) -> String { values.map(String.init).joined(separator: ",") }
    static func memberID(_ mode: Mode) -> UUID? { if case .group(let member, _, _) = mode { member } else { nil } }
    static func isGroup(_ mode: Mode) -> Bool { memberID(mode) != nil }
}
