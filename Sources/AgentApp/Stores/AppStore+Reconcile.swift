import Foundation

/// P16 reconcile timing, all injectable.
struct ReconcileTiming: Sendable {
    /// Rows per window (`limit` is one more: the extra row stitches windows together) and windows per automatic pass.
    var window = 60; var maxWindows = 5; var maxFullWindows = 1_000
    /// Box bytes one sweep may read.
    var byteCap = 4_000_000
    /// Automatic passes per session at most this often; an opened chat waits longer. The cut-turn schedule is exempt.
    var floor: Duration = .seconds(15); var openFloor: Duration = .seconds(30)
    /// After a cut stream: passes at these offsets; a pass that cannot reach the box uses no slot and repeats after these.
    var schedule: [Duration] = [.zero, .seconds(3), .seconds(10), .seconds(30), .seconds(90)]
    var unreachable: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(120), .seconds(600)]
    /// An active run keeps polling (no slot used) for at most this long; unchanged text this far apart stops polling.
    var activeCap: Duration = .seconds(1_800); var unchangedStop: Duration = .seconds(10)
    var notSentAge: TimeInterval = 120
    /// Launch sweep: passes in flight.
    var sweepWidth = 3
    static let standard = ReconcileTiming()
}

enum ReconcileReason: Sendable { case open, launch, interrupted, wake, path, recovered, refresh, schedule, retry, headless
    var isAutomatic: Bool { ![.refresh, .schedule, .retry, .headless].contains(self) }
}

/// What one pass found, for footers, Retry and `--reconcile` lines (names and counts only).
struct ReconcileReport: Sendable {
    var segments: [(name: String, counts: HistoryReconciler.Counts)] = []
    var read = 0, total = 0
    var problems: [String] = []
    var changed = false, unreachable = false, skipped = false, activeRun = false
    var changedRows: Set<UUID> = []
    /// Per the last unit read: box time of its oldest row (nil = whole session), the box clock minus the Mac's, whether
    /// an unpaired box turn is newer than the last paired one.
    var coversFrom: Date?; var skew: TimeInterval = 0; var newerUnmatched = false
}

/// One session to read: a bot chat, a thread, or one member of a group.
struct ReconcileUnit {
    let conversation: any Conversation; let bot: Bot; let sessionID: String; let mode: HistoryReconciler.Mode; let name: String
}

struct SessionRead: Sendable { var rows: [BackendMessage]; var coversFrom: Date?; var missing: Bool; var serverDate: Date?; var bytes: Int }

/// P16 Part 1: reconcile from the box (GET only; writes only this store).
extension AppStore {
    /// Opening a chat (a user action) reads its server history; for OpenClaw this may connect the Gateway (P12).
    func loadServerHistory(for bot: Bot) {
        guard bot.backend.hasServerSessions, isIdle(bot), bot.threads.allSatisfy(isIdle), !needsKey(bot), bot.backend != .openClaw || bot.openClaw != nil else { return }
        refreshFeatures(for: bot)
        let token = UUID(); historyLoadTokens[bot.id] = token
        Task {
            // No session yet: only the transport is learned (as before P16); nothing is read or adopted.
            if reconcileUnits(for: bot).isEmpty { _ = try? await backend(for: bot).sessionTransport(); return }
            await reconcile(bot, reason: .open)
            if bot.backend == .openClaw { refreshFeatures(for: bot) } // the history read connected the Gateway (P12)
        }
    }

    /// Sessions a conversation reads: a bot's chat and threads; each group member (and each former author whose bot still exists).
    func reconcileUnits(for conversation: any Conversation) -> [ReconcileUnit] {
        if let bot = conversation as? Bot {
            var units: [ReconcileUnit] = []
            if let session = bot.hermesSessionID { units.append(.init(conversation: bot, bot: bot, sessionID: session, mode: .chat(additions: true), name: bot.name)) }
            for thread in bot.threads { if let session = thread.hermesSessionID { units.append(.init(conversation: thread, bot: bot, sessionID: session, mode: .chat(additions: false), name: "\(bot.name) thread")) } }
            return units
        }
        if let thread = conversation as? ChatThread, let session = thread.hermesSessionID, let bot = bots.first(where: { $0.threads.contains { $0 === thread } }) {
            return [.init(conversation: thread, bot: bot, sessionID: session, mode: .chat(additions: false), name: "\(bot.name) thread")]
        }
        guard let group = conversation as? GroupChat else { return [] }
        let authors = Set(group.messages.compactMap(\.authorID))
        let names = bots.map(\.name)
        return bots.filter { group.memberIDs.contains($0.id) || authors.contains($0.id) }.compactMap { bot in
            guard group.session(for: bot.id) != nil || authors.contains(bot.id) else { return nil }
            let session = group.session(for: bot.id) ?? sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id)
            return .init(conversation: group, bot: bot, sessionID: session, mode: .group(member: bot.id, names: names, user: userName), name: bot.name)
        }
    }

    func isStreamingIn(_ conversation: any Conversation) -> Bool {
        // P42: a live card (another bot's work, a routine) is no turn of this chat; it never holds the reconcile back.
        isStreaming(in: conversation) || conversation.messages.contains { $0.isStreaming && $0.presentation != .botMessage }
    }

    /// One pass over a conversation. Automatic passes keep a floor per session and never raise `errorMessage`.
    @discardableResult func reconcile(_ conversation: any Conversation, reason: ReconcileReason, full: Bool = false, ignoringStream: Bool = false, member: UUID? = nil) async -> ReconcileReport {
        var report = ReconcileReport()
        guard ignoringStream || !isStreamingIn(conversation) else { report.skipped = true; return report }
        for unit in reconcileUnits(for: conversation) where member == nil || unit.bot.id == member {
            report.total += 1
            // P39: a thread can stream while its bot's chat is read; its own turn is never adopted mid-stream.
            if !ignoringStream, unit.conversation !== conversation, isStreamingIn(unit.conversation) { report.skipped = true; continue }
            let key = "\(unit.bot.id)|\(unit.sessionID)"
            if turns.running.contains(key) { report.skipped = true; continue }
            if reason.isAutomatic, let last = turns.lastPass[key], ContinuousClock.now - last < (reason == .open ? reconcileTiming.openFloor : reconcileTiming.floor) { continue }
            turns.running.insert(key); turns.lastPass[key] = .now
            defer { turns.running.remove(key) }
            await reconcileUnit(unit, full: full, ignoringStream: ignoringStream, into: &report)
        }
        if report.changed { objectWillChange.send(); save() }
        return report
    }

    private func reconcileUnit(_ unit: ReconcileUnit, full: Bool, ignoringStream: Bool, into report: inout ReconcileReport) async {
        guard !needsKey(unit.bot), let activeBackend = try? backend(for: unit.bot) else { report.problems.append("\(unit.name): no readable key"); return }
        // A box that answered (e.g. 401 for a rejected key, P28 D6) is not "unreachable": no quick retries for it.
        do { if try await activeBackend.sessionTransport() == .legacyChatCompletions { return } } catch { report.unreachable = !(error is BackendError); report.problems.append("\(unit.name): read failed"); return }
        let snapshot = unit.conversation.messages.map(HistoryReconciler.LocalRow.init)
        let oldestNeeded = snapshot.filter { $0.role == .assistant && ($0.state == .incomplete || $0.state == .notSent || ($0.isEmpty && $0.state != .finished && $0.state != .stopped)) }.map(\.createdAt).min()
        let read: SessionRead
        do { read = try await readSession(activeBackend, sessionID: unit.sessionID, needBackTo: oldestNeeded, full: full) }
        catch { report.unreachable = !(error is BackendError); report.problems.append("\(unit.name): read failed"); turns.failureStreak += report.unreachable ? 1 : 0; return }
        report.read += 1
        if turns.failureStreak > 0 { turns.failureStreak = 0 }
        var active: Set<UUID> = []
        for row in snapshot where row.role == .assistant && row.state == .incomplete {
            guard let run = row.metadata[TurnKey.run], let status = try? await activeBackend.runStatus(runID: run) else { continue }
            if ["queued", "running", "waiting_for_approval", "stopping"].contains(status) { active.insert(row.id) }
        }
        if !active.isEmpty { report.activeRun = true }
        let skew = read.serverDate.map { $0.timeIntervalSinceNow } ?? 0
        let plan = HistoryReconciler.plan(.init(local: snapshot, server: read.rows, mode: unit.mode, now: .now, skew: skew, coversFrom: read.coversFrom, activeRuns: active, notSentAge: reconcileTiming.notSentAge))
        report.segments.append((unit.name, plan.counts))
        report.coversFrom = read.coversFrom; report.skew = skew; report.newerUnmatched = plan.newerUnmatched
        guard ignoringStream || !isStreamingIn(unit.conversation) else { report.skipped = true; return }
        let isBotChat: Bool; if case .chat(true) = unit.mode { isBotChat = true } else { isBotChat = false }
        if isBotChat, !read.missing, plan.diverged || (read.rows.isEmpty && snapshot.contains { $0.role != .system && !$0.isEmpty }) {
            let note = "Hermes history was not merged because it diverges from this local conversation."
            if unit.conversation.messages.last?.content != note { unit.conversation.messages.append(ChatMessage(role: .system, content: note)); report.changed = true }
            return
        }
        apply(plan, snapshot: snapshot, to: unit, report: &report)
    }

    /// Applies a plan to rows that did not change since the snapshot; added rows alone bump the unread count.
    func apply(_ plan: HistoryReconciler.Plan, snapshot: [HistoryReconciler.LocalRow], to unit: ReconcileUnit, report: inout ReconcileReport) {
        let conversation = unit.conversation
        let before = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        func unchanged(_ row: ChatMessage) -> Bool {
            guard let old = before[row.id] else { return false }
            return !row.isStreaming && row.turnState == old.state && row.content == old.text && row.turnState != .stopped && row.turnState != .finished
        }
        for edit in plan.edits {
            guard let row = conversation.messages.first(where: { $0.id == edit.rowID }), unchanged(row) else { continue }
            if let content = edit.content { row.content = content }
            if let state = edit.state { row.turnState = state }
            if let activity = edit.activity, (row.activity?.total ?? 0) == 0 { row.activity = activity }
            for (key, value) in edit.metadata { row.metadata[key] = value }
            report.changed = true; report.changedRows.insert(row.id)
        }
        var added = 0
        for addition in plan.additions {
            let rows = addition.rows.map { new in
                let row = ChatMessage(role: new.role, content: new.content, createdAt: new.createdAt, metadata: new.metadata, authorID: new.authorID, turnState: new.state)
                row.activity = new.activity
                return row
            }
            added += rows.filter { $0.role == .assistant }.count
            if let after = addition.after {
                guard let index = conversation.messages.firstIndex(where: { $0.id == after }) else { continue }
                conversation.messages.insert(contentsOf: rows, at: index + 1)
            } else { conversation.messages.append(contentsOf: rows) }
            rows.forEach { report.changedRows.insert($0.id) }
            report.changed = true
        }
        guard added > 0 else { return }
        if let group = conversation as? GroupChat, selectedGroup?.id != group.id { group.unreadCount += added }
        if let bot = conversation as? Bot, selectedBot !== bot || selectedGroup != nil { bot.unreadCount += added }
    }

    /// Reads the newest windows (`limit` = window + 1, `offset` = window·k): each window's newest row must be the previous
    /// window's oldest, else rows landed or vanished between GETs and the pass fails as a read failure. Widens while a page
    /// is full and the oldest row to check is not covered, at most `maxWindows` (`full`: everything).
    func readSession(_ activeBackend: any AgentBackend, sessionID: String, needBackTo: Date?, full: Bool) async throws -> SessionRead {
        let size = reconcileTiming.window
        var merged: [BackendMessage] = []; var serverDate: Date?; var bytes = 0
        for k in 0..<(full ? reconcileTiming.maxFullWindows : reconcileTiming.maxWindows) {
            let page = try await activeBackend.recentMessages(sessionID: sessionID, window: size + 1, offset: size * k)
            if page.missing { return SessionRead(rows: merged, coversFrom: nil, missing: k == 0, serverDate: page.serverDate ?? serverDate, bytes: bytes) }
            serverDate = serverDate ?? page.serverDate; bytes += page.bytes
            if k == 0 { merged = page.rows }
            else {
                guard let stitch = page.rows.last, let first = merged.first, Self.sameRow(stitch, first) else { throw BackendError.unavailable("The box changed while it was read.") }
                merged = page.rows.dropLast() + merged
            }
            guard page.full else { return SessionRead(rows: merged, coversFrom: nil, missing: false, serverDate: serverDate, bytes: bytes) }
            if bytes > reconcileTiming.byteCap { break }
            if !full {
                let skew = serverDate.map { $0.timeIntervalSinceNow } ?? 0
                guard let needBackTo, let oldest = merged.first?.createdAt, oldest > needBackTo.addingTimeInterval(skew) else { break }
            }
        }
        return SessionRead(rows: merged, coversFrom: merged.first?.createdAt ?? .distantFuture, missing: false, serverDate: serverDate, bytes: bytes)
    }

    nonisolated static func sameRow(_ a: BackendMessage, _ b: BackendMessage) -> Bool {
        if let left = a.id, let right = b.id { return left == right }
        return a.role == b.role && a.content == b.content
    }

    // MARK: Triggers

    /// The conversation holding a row.
    func conversation(containing rowID: UUID) -> (any Conversation)? {
        for bot in bots {
            if bot.messages.contains(where: { $0.id == rowID }) { return bot }
            if let thread = bot.threads.first(where: { $0.messages.contains { $0.id == rowID } }) { return thread }
        }
        return groups.first { $0.messages.contains { $0.id == rowID } }
    }

    /// Conversations holding an `incomplete` or `notSent` row or a pending round, plus the open one.
    func attentionConversations() -> [any Conversation] {
        func needs(_ conversation: any Conversation) -> Bool { conversation.messages.contains { $0.turnState == .incomplete || $0.turnState == .notSent } }
        var result: [any Conversation] = []
        for bot in bots where bot.backend == .hermes {
            if needs(bot) || (selectedGroup == nil && selectedBot === bot) { result.append(bot) }
            result += bot.threads.filter(needs).map { $0 as any Conversation }
        }
        result += groups.filter { needs($0) || $0.round != nil || selectedGroup?.id == $0.id }.map { $0 as any Conversation }
        return result
    }

    /// Wake, path restored, first success after a failure streak.
    func reconcileAttention(reason: ReconcileReason) {
        let targets = attentionConversations()
        Task { for target in targets { await reconcile(target, reason: reason) } }
    }

    /// D2: every Hermes chat once, in the background, a few at a time; skipped offline.
    func launchSweep() async {
        guard !turns.pathDown else { return }
        var targets: [any Conversation] = bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && ($0.hermesSessionID != nil || !$0.threads.isEmpty) }
        targets += groups.filter { !$0.sessions.isEmpty }.map { $0 as any Conversation }
        var index = 0
        while index < targets.count {
            let batch = targets[index..<min(index + reconcileTiming.sweepWidth, targets.count)]
            let running = batch.map { target in Task { await self.reconcile(target, reason: .launch) } }
            for task in running { _ = await task.value }
            index += reconcileTiming.sweepWidth
        }
    }

    /// The footer's Refresh: a pass at once; the result is the row's footer, never an alert.
    func refresh(_ row: ChatMessage) {
        guard let conversation = conversation(containing: row.id) else { return }
        row.metadata[TurnKey.check] = "checking"
        Task {
            let report = await reconcile(conversation, reason: .refresh)
            if row.metadata[TurnKey.check] == "checking" {
                row.metadata[TurnKey.check] = report.unreachable || (report.read == 0 && report.total > 0) ? "Can't reach the box." : report.changedRows.contains(row.id) ? nil : "The box has nothing more yet."
            }
        }
    }
}
