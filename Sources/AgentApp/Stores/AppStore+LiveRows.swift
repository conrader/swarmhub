import Foundation

/// P46 2: memory only. Per bot: the last `message_count|last_active` of its main session and when it is read next.
struct LiveRowsState {
    static let idle: TimeInterval = 15, active: TimeInterval = 5
    var marks: [UUID: String] = [:]
    var nextRead: [UUID: Date] = [:]
}

/// P46 2: rows the box appends to a bot's Bot Chat by itself (a `bot-chat:` routine's output and the bot's reply to it)
/// reach the app. Each bot's main session is looked up in the session list SwarmHub already reads (every 15 s, 5 s while
/// a routine of that bot runs); when its size or last activity moved, the P16 reconcile adds the box turns this app did
/// not write (in order, never twice). A delivered routine row then reads "Woken by: heartbeat" (or "routine <name>"), and
/// an exchange whose reply is exactly `[SILENT]` is hidden (P44).
extension AppStore {
    /// One pass over every Hermes bot that is due; the routine poll's 5 s tick calls it.
    func pollLiveRowsOnce(now: Date = .now) async {
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive && bot.hermesSessionID != nil && !needsKey(bot) {
            guard (liveRows.nextRead[bot.id] ?? .distantPast) <= now else { continue }
            liveRows.nextRead[bot.id] = now.addingTimeInterval(routineRunning(for: bot) ? LiveRowsState.active : LiveRowsState.idle)
            await readLiveRows(bot)
        }
    }

    /// A routine of this bot runs now (the box says so, or Run now is being watched).
    func routineRunning(for bot: Bot) -> Bool {
        let state = routines.state(for: bot.id)
        return !state.running.isEmpty || state.jobs.value?.contains { $0.state == "running" } == true
    }

    func readLiveRows(_ bot: Bot) async {
        guard let session = bot.hermesSessionID, let backend = try? backend(for: bot) as? HermesBackend,
              let rows = try? await backend.sessionListing(source: "api_server") else { return }
        // P46 1: "on connect" — the first answer from the box titles the main chat (once).
        if !hasBotChat(bot), botChatConflict(bot) == nil { await ensureBotChat(bot) }
        guard let row = rows.first(where: { $0.id == session }), bot.hermesSessionID == session else { return }
        guard let seen = liveRows.marks[bot.id] else { liveRows.marks[bot.id] = row.mark; return }
        guard row.mark != seen, !isStreamingIn(bot), isIdle(bot) else { return }
        let report = await reconcile(bot, reason: .schedule)
        guard !report.skipped, report.read > 0 else { return }
        liveRows.marks[bot.id] = row.mark
        labelDeliveredRows(in: bot)
    }

    /// Marks each routine row the box delivered (once): who woke the bot, and `[SILENT]` exchanges hidden.
    func labelDeliveredRows(in bot: Bot) {
        var changed = false
        let messages = bot.messages
        for (index, row) in messages.enumerated() where row.role == .user && row.metadata[AutomationKey.woken] == nil {
            guard let name = CronDeliveryRow.jobName(row.content) else { continue }
            let heartbeat = isHeartbeatName(name, bot: bot)
            // A loop or goal the box ran while SwarmHub was closed (`AppStore+AutomationHandoff.swift`).
            let handed: AutomationKind? = name.hasPrefix("swarmhub-loop-") ? .loop : name.hasPrefix("swarmhub-goal-") ? .goal : nil
            row.metadata[AutomationKey.woken] = handed?.rawValue ?? (heartbeat ? AutomationKind.heartbeat.rawValue : "routine \(name)")
            row.metadata[AutomationKey.display] = handed.map { $0 == .loop ? "Loop (on the box)" : "Goal (on the box)" } ?? (heartbeat ? "Heartbeat" : "Routine: \(name)")
            let replies = messages[(index + 1)...].prefix { $0.role != .user }.filter { $0.role == .assistant }
            if !replies.isEmpty, replies.allSatisfy(\.isSilent) {
                row.metadata[AutomationKey.silent] = "1"; replies.forEach { $0.metadata[AutomationKey.silent] = "1" }
            } else if let reply = replies.last(where: { !$0.isSilent }), now().timeIntervalSince(reply.createdAt) < 600 {
                notifyIfNeeded(bot: bot, message: technicalLine(reply, botName: bot.name))
            }
            changed = true
        }
        if changed { objectWillChange.send(); save() }
    }

    /// The bot's heartbeat routine (P46 3) or, with no job list yet, any routine named like one.
    func isHeartbeatName(_ name: String, bot: Bot) -> Bool {
        if let job = heartbeatJob(for: bot) { return job.name == name }
        return name == HeartbeatPlan.jobName || name.lowercased().contains("heartbeat")
    }
}
