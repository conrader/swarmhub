import Foundation

/// When SwarmHub quits, a running `/loop` or `/goal` in a bot's Bot Chat keeps going on its box: one Hermes routine per
/// chat (`swarmhub-loop-<chat id>` / `swarmhub-goal-<chat id>`, deliver `bot-chat:<profile>`). Like a heartbeat, its run
/// only repeats the prompt, and Hermes hands that to the Bot Chat for a full turn, so the bot works with the chat's
/// context. At the next launch SwarmHub pauses the routine first (nothing runs after that), reads the box's turns into the
/// chat, counts the rounds, deletes the routine and drives the loop or goal itself again. Without a jobs API, a Bot Chat or
/// a reachable box at quit, the loop or goal stays in the app and waits for it, as before (threads and groups always do).
extension AppStore {
    /// A goal on the box gets a round every 15 minutes (in the app the next round follows each reply).
    static let goalBoxInterval: TimeInterval = 900

    struct HandoffPlan: Sendable {
        let id: UUID, client: HermesJobsClient, name: String, schedule: String, prompt: String, deliver: String, times: Int?
        let kind: AutomationKind
    }

    static func handoffName(_ kind: AutomationKind, chat id: UUID) -> String { "swarmhub-\(kind.rawValue)-\(id.uuidString.prefix(8).lowercased())" }

    /// The routine's own run only repeats the text; the Bot Chat turn it is handed to does the work.
    static func handoffPrompt(_ text: String) -> String {
        "Reply with exactly the text between the two lines below, without the lines and without adding anything.\n-----\n\(text)\n-----"
    }

    func handoffPlans(now: Date) -> [HandoffPlan] {
        automations.compactMap { entry -> HandoffPlan? in
            let (id, automation) = (entry.key, entry.value)
            guard automation.boxHandoff == nil, let (bot, conversation) = automationConversation(id), conversation.id == bot.id,
                  bot.backend == .hermes, hasBotChat(bot), botChatConflict(bot) == nil, routines.state(for: bot.id).hasJobsAPI,
                  let client = try? jobsClient(for: bot) else { return nil }
            let deliver = HeartbeatPlan.delivery(profile(of: bot))
            if let loop = automation.loop, !loop.paused, loop.timesLeft.map({ $0 > 0 }) ?? true {
                let minutes = max(1, Int((loop.interval / 60).rounded()))
                return HandoffPlan(id: id, client: client, name: Self.handoffName(.loop, chat: id), schedule: "every \(minutes)m",
                                   prompt: Self.handoffPrompt(loop.message), deliver: deliver, times: loop.timesLeft, kind: .loop)
            }
            if let goal = automation.goal, goal.state == .running {
                let rounds = min(goal.maxRounds - goal.round, Int(goal.deadline.timeIntervalSince(now) / Self.goalBoxInterval))
                guard rounds > 0 else { return nil }
                return HandoffPlan(id: id, client: client, name: Self.handoffName(.goal, chat: id),
                                   schedule: "every \(Int(Self.goalBoxInterval / 60))m", prompt: Self.handoffPrompt(GoalProtocol.boxContinuation(goal)),
                                   deliver: deliver, times: rounds, kind: .goal)
            }
            return nil
        }
    }

    /// Quit (before the final save): hands loops and goals to their boxes and ends the presence leases. The requests run
    /// on a detached task; the main thread waits at most `budget` seconds. A handoff is saved before its request, so a
    /// routine the box created after the wait gave up is still found (by name) and taken back at launch.
    func handOffForQuit(budget: TimeInterval = 4) {
        let plans = handoffPlans(now: now()), endings = presenceEndings
        guard !plans.isEmpty || !endings.isEmpty else { return }
        let stamp = now()
        for plan in plans { automations[plan.id]?.boxHandoff = BoxHandoff(kind: plan.kind, jobName: plan.name, jobID: nil, handedAt: stamp) }
        if !plans.isEmpty { flushNow() }
        let created = LockedValue<[UUID: String]>([:]), done = DispatchSemaphore(value: 0)
        Task.detached {
            let ids = await withTaskGroup(of: (UUID, String)?.self) { group -> [UUID: String] in
                for plan in plans {
                    group.addTask {
                        guard let job = try? await plan.client.create(name: plan.name, schedule: plan.schedule, prompt: plan.prompt,
                                                                      deliver: plan.deliver, repeat: plan.times) else { return nil }
                        return (plan.id, job.id)
                    }
                }
                for ending in endings {
                    group.addTask { _ = try? await ending.client.update(ending.id, prompt: PresenceLease.prompt(until: .distantPast)); return nil }
                }
                var found: [UUID: String] = [:]
                for await result in group { if let result { found[result.0] = result.1 } }
                return found
            }
            _ = created.swap(ids)
            done.signal()
        }
        _ = done.wait(timeout: .now() + budget)
        for (id, jobID) in created.current { automations[id]?.boxHandoff?.jobID = jobID }
    }

    /// Each routine poll tick until none is left: takes back what was handed to a box. A box that cannot be reached keeps
    /// it (nothing runs here meanwhile, so nothing runs twice) and the next tick tries again.
    func reclaimHandoffs() async {
        for (id, automation) in automations {
            guard let handoff = automation.boxHandoff, boxAlerts.reclaiming.insert(id).inserted else { continue }
            await reclaim(handoff, chat: id)
            boxAlerts.reclaiming.remove(id)
        }
    }

    /// Pauses the routine (no new round starts), reads the Bot Chat from the box and only then deletes the routine and
    /// continues here. A read that fails, did not happen (no session reads) or leaves the box's turns unmerged keeps the
    /// routine (paused) and the handoff, and says why in the chat; a busy chat is read next tick. A round still in flight
    /// is waited for however long it runs; rounds the box counted that are not in the chat yet for `handoffSettle`, and
    /// past that until the user takes it over anyway (`/loop takeover`, `/goal takeover`) or stops it. So nothing runs
    /// twice and the counts are the box's.
    func reclaim(_ handoff: BoxHandoff, chat id: UUID) async {
        guard let (bot, conversation) = automationConversation(id) else { automations[id] = nil; save(); return }
        guard let client = try? jobsClient(for: bot) else { return }
        var job: HermesJob?
        do {
            let rows = try await client.listAll()
            job = rows.first(where: { $0.id == handoff.jobID }) ?? rows.first(where: { $0.name == handoff.jobName })
            if let found = job, !found.isPaused { job = try await client.pause(found.id) }
        } catch HermesJobsError.notFound {
        } catch { return handoffBlocked(id, in: conversation, HandoffCopy.unreachable(handoff.kind)) }
        let resumable = handoff.kind == .loop ? loop(in: conversation) != nil : goal(in: conversation)?.isActive == true
        var replies: [ChatMessage] = []
        if resumable {
            // The whole session: a long handoff's rounds can reach past the newest windows.
            let report = await reconcile(bot, reason: .schedule, full: true, chatOnly: true)
            if report.unreachable || !report.problems.isEmpty || report.notMerged || report.legacy
                || (report.leftOut[handoff.jobName].map { $0 >= handoff.handedAt.addingTimeInterval(-60) } ?? false) {
                return handoffBlocked(id, in: conversation, HandoffCopy.notReconciled(handoff.kind))
            }
            if report.skipped { // the chat is busy: read again next tick; one that stays busy is said once
                if waitClock(handoff, id, for: "busy") >= Self.handoffSettle { handoffBlocked(id, in: conversation, HandoffCopy.notReconciled(handoff.kind)) }
                return
            }
            // Only a chat actually read and merged goes on, or one the box has no session for while its routine is there
            // and never ran (nothing of it can be missing). Anything else is unknown: kept, said, tried again.
            let neverRan = job.map { !$0.isRunning && ($0.runsCompleted ?? 0) == 0 && $0.lastRunAt == nil } ?? false
            guard report.total > 0, report.read == report.total, !report.missing || neverRan else {
                return handoffBlocked(id, in: conversation, HandoffCopy.notReconciled(handoff.kind))
            }
            labelDeliveredRows(in: bot)
            replies = boxReplies(in: bot, jobName: handoff.jobName, after: handoff.handedAt)
            let inFlight = job?.isRunning == true, behind = (job?.runsCompleted ?? 0) > replies.count
            if inFlight || behind {
                let waited = waitClock(handoff, id, for: inFlight ? "running" : "behind")
                // A run in flight is not counted yet (Hermes counts it after its delivery): deleting it then could run that
                // round twice, so it is never taken over. Past the long wait the chat says so once; a stop ends it.
                if inFlight {
                    if waited >= 3 * Self.handoffSettle { handoffBlocked(id, in: conversation, HandoffCopy.stillRunning(handoff.kind)) }
                    return
                }
                if waited < Self.handoffSettle { return }
                // Past the wait the missing rounds' replies (an `--until` met, a goal's done block) are still unknown: the
                // routine stays paused on the box until the user takes it over anyway (the box's count) or stops it.
                if handoff.takeOver != true { return handoffBlocked(id, in: conversation, HandoffCopy.roundsMissing(handoff.kind)) }
            }
        }
        if let found = job {
            do { try await client.delete(found.id) } catch HermesJobsError.notFound {
            } catch { return handoffBlocked(id, in: conversation, HandoffCopy.unreachable(handoff.kind)) }
        }
        automations[id]?.boxHandoff = nil
        save()
        // The box's own count wins: a round it ran whose reply never reached the chat (taken over anyway) still counts.
        let rounds = max(replies.count, job?.runsCompleted ?? 0), lastRun = job?.lastRunAt.flatMap(RoutineTime.date)
        if resumable {
            switch handoff.kind {
            case .loop: resumeLoop(in: conversation, bot: bot, rounds: rounds, last: replies.last, lastRun: lastRun)
            case .goal: resumeGoal(in: conversation, bot: bot, rounds: rounds, last: replies.last)
            case .heartbeat: break
            }
        }
        pruneAutomations(conversation)
    }

    /// How long a reclaim waits for rounds the box counted but the chat lacks (a run in flight is waited for as long as
    /// it runs; after three times this the chat says so).
    static let handoffSettle: TimeInterval = 1_200

    /// How long this reclaim has been waiting (busy chat, a run in flight, rounds not in the chat yet); starts the clock.
    private func waitClock(_ handoff: BoxHandoff, _ id: UUID, for reason: String) -> TimeInterval {
        guard let since = handoff.waitingSince, handoff.waitingFor == reason else {
            automations[id]?.boxHandoff?.waitingSince = now(); automations[id]?.boxHandoff?.waitingFor = reason; save()
            return 0
        }
        return now().timeIntervalSince(since)
    }

    /// The handoff stays (its routine paused on the box); a new reason is said once in the chat.
    private func handoffBlocked(_ id: UUID, in conversation: any Conversation, _ reason: String) {
        guard automations[id]?.boxHandoff != nil, automations[id]?.boxHandoff?.lastError != reason else { return }
        automations[id]?.boxHandoff?.lastError = reason
        commandLine(reason, in: conversation)
    }

    /// `/loop takeover`, `/goal takeover`: after `roundsMissing`, the next tick takes it back with the box's count.
    func takeOverHandoff(in conversation: any Conversation) {
        guard let handoff = automations[conversation.id]?.boxHandoff else { return }
        guard handoff.lastError == HandoffCopy.roundsMissing(handoff.kind) else {
            commandLine(HandoffCopy.nothingToTakeOver(handoff.kind), in: conversation); return
        }
        automations[conversation.id]?.boxHandoff?.takeOver = true; save()
        commandLine(HandoffCopy.takingOver(handoff.kind), in: conversation)
    }

    /// The bot's replies to the routine's deliveries since the handoff, oldest first.
    func boxReplies(in bot: Bot, jobName: String, after: Date) -> [ChatMessage] {
        let messages = bot.messages
        var replies: [ChatMessage] = []
        for (index, row) in messages.enumerated() where row.role == .user && row.createdAt >= after.addingTimeInterval(-60)
            && CronDeliveryRow.jobName(row.content) == jobName {
            if let reply = messages[(index + 1)...].prefix(while: { $0.role != .user }).last(where: { $0.role == .assistant }) { replies.append(reply) }
        }
        return replies
    }

    private func resumeLoop(in conversation: any Conversation, bot: Bot, rounds: Int, last: ChatMessage?, lastRun: Date?) {
        guard let loop = loop(in: conversation) else { return }
        updateLoop(in: conversation) { run in
            run.runs += rounds
            if let left = run.timesLeft { run.timesLeft = max(0, left - rounds) }
            run.awaitingReply = false
            run.nextAt = max(now(), (lastRun ?? now()).addingTimeInterval(run.interval))
        }
        if rounds > 0 { commandLine(HandoffCopy.loopRan(rounds), in: conversation) }
        if let until = loop.until, let last, LoopRun.loopDone(in: last.finalText) { endLoop(in: conversation, line: "Loop ended: \(until)."); return }
        if let current = self.loop(in: conversation), current.timesLeft == 0 {
            endLoop(in: conversation, line: "Loop finished after \(current.runs) \(current.runs == 1 ? "run" : "runs").")
        }
    }

    private func resumeGoal(in conversation: any Conversation, bot: Bot, rounds: Int, last: ChatMessage?) {
        guard goal(in: conversation)?.isActive == true else { return }
        updateGoal(in: conversation) { $0.round += rounds; $0.awaitingReply = false }
        if rounds > 0 { commandLine(HandoffCopy.goalRan(rounds), in: conversation) }
        // The last box round's reply ends the goal (done, blocked) or the app sends the next round, as after any reply.
        if let last {
            updateGoal(in: conversation) { $0.awaitingReply = true }
            goalTurnEnded(in: conversation, bot: bot, reply: last, outcome: TurnOutcome(state: .finished))
        } else {
            advanceGoal(in: conversation, bot: bot)
        }
    }
}

enum HandoffCopy {
    static func loopRan(_ count: Int) -> String {
        "While SwarmHub was closed, the box ran this loop \(count == 1 ? "once" : "\(count) times"). It runs here again now."
    }
    static func goalRan(_ count: Int) -> String {
        "While SwarmHub was closed, the box ran \(count == 1 ? "one round" : "\(count) rounds") of this goal. It continues here now."
    }
    static func unreachable(_ kind: AutomationKind) -> String {
        "SwarmHub can't reach the box to take this \(kind.rawValue) back yet. It stays on the box and SwarmHub tries again."
    }
    static func stillRunning(_ kind: AutomationKind) -> String {
        "The box is still running a round of this \(kind.rawValue). SwarmHub waits for it to finish before taking the \(kind.rawValue) back, so nothing runs twice. Stop the \(kind.rawValue) to end it."
    }
    static func roundsMissing(_ kind: AutomationKind) -> String {
        "The box ran rounds of this \(kind.rawValue) whose replies aren't in the chat, so a reply that ended it may be missing. It stays paused on the box. Type /\(kind.rawValue) takeover to continue it here anyway, counting the box's rounds, or stop the \(kind.rawValue) to end it."
    }
    static func takingOver(_ kind: AutomationKind) -> String {
        "SwarmHub takes this \(kind.rawValue) back from the box now, counting the rounds the box ran."
    }
    static func nothingToTakeOver(_ kind: AutomationKind) -> String {
        "This \(kind.rawValue) is still on the box and SwarmHub is taking it back by itself; there is nothing to take over."
    }
    static func notReconciled(_ kind: AutomationKind) -> String {
        "SwarmHub couldn't read this chat's history from the box, so this \(kind.rawValue) stays paused there and SwarmHub tries again. Stop the \(kind.rawValue) to end it."
    }
}
