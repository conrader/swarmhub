import Foundation

/// P46 4: what "Apply to…" is doing, and each bot's last heartbeat problem (memory only).
struct HeartbeatBatchState: Equatable {
    var applying: Set<UUID> = []
    var problems: [UUID: String] = [:]
    var summary: String?
}

enum HeartbeatCopy {
    static func none(_ name: String) -> String { "No heartbeat for \(name). Type /heartbeat every 1h 08:00–23:00." }
    static let usage = "Say how often: /heartbeat every 1h [08:00–23:00] [<prompt>]."
    /// "Up to 32 agent turns a day: 16 wakes, two turns each one that has something to say."
    static func turns(_ wakes: Int) -> String { "Up to \(wakes * 2) agent turns a day: \(wakes) \(wakes == 1 ? "wake" : "wakes"), two turns for each one that has something to say." }
    static func started(_ name: String, plan: HeartbeatPlan, wakes: Int, replaced: Bool) -> String {
        "\(replaced ? "Heartbeat updated" : "Heartbeat on") for \(name): \(plan.label). Hermes runs it as the routine \(HeartbeatPlan.jobName) and answers in this chat (Bot Chat); a [SILENT] answer stays hidden. \(turns(wakes))"
    }
}

/// P46 3: `/heartbeat every 1h 08:00–23:00 [prompt]`, `/heartbeat status|pause|resume|stop` and Settings → Heartbeat drive
/// one Hermes routine per bot: `swarmhub-heartbeat`, `deliver: bot-chat:<profile>`, its cron in the box's time zone at the
/// bot's staggered minute. An existing `bot-chat:` routine of that profile named like a heartbeat (Jarvis's) is adopted
/// instead of creating a second one; Stop deletes SwarmHub's own routine and only pauses an adopted one. SwarmHub runs
/// no timer of its own any more (P45's is gone).
extension AppStore {
    func heartbeatJob(for bot: Bot) -> HermesJob? {
        routines.state(for: bot.id).jobs.value.flatMap { Self.heartbeatJob(in: $0, profile: profile(of: bot)) }
    }

    static func heartbeatJob(in jobs: [HermesJob], profile: String) -> HermesJob? {
        jobs.first { $0.name == HeartbeatPlan.jobName }
            ?? jobs.first { $0.deliver == HeartbeatPlan.delivery(profile) && $0.name.lowercased().contains("heartbeat") }
    }

    /// P46 5: the routine's output is a turn in this bot's Bot Chat, so its result shows there (item 2), not as a card.
    func deliversToBotChat(_ job: HermesJob, bot: Bot) -> Bool { job.deliver == HeartbeatPlan.delivery(profile(of: bot)) }

    /// Heartbeats at once on one box: its advised coding slots (P31 E), one while the box was never checked.
    func heartbeatCap(on connection: String) -> Int { boxReadings(on: connection).capacity.map { BoxCapacity($0).advised } ?? 1 }

    /// The bot's minute past the hour, spread over every Hermes bot of its box and capped by the box's capacity.
    func heartbeatStagger(for bot: Bot) -> Int {
        let box = connection(of: bot)
        let profiles = bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && connection(of: $0) == box }.map(profile(of:))
        return HeartbeatStagger.minutes(for: profiles + [profile(of: bot)], cap: heartbeatCap(on: box))[profile(of: bot)] ?? 0
    }

    /// The box's cron time zone from a time it reported (UTC when none of its jobs says).
    static func boxOffset(_ jobs: [HermesJob]) -> Int {
        jobs.lazy.compactMap { CronDeliveryRow.offsetMinutes($0.nextRunAt) ?? CronDeliveryRow.offsetMinutes($0.lastRunAt) }.first ?? 0
    }

    var heartbeatLocalOffset: Int { heartbeatTimeZone.secondsFromGMT(for: now()) / 60 }

    // MARK: The routine

    /// Creates or edits the bot's heartbeat routine for `plan` (after titling its Bot Chat) and resumes it when paused.
    /// nil on success, else why not.
    func applyHeartbeat(_ plan: HeartbeatPlan, to bot: Bot) async -> String? {
        heartbeatBatch.applying.insert(bot.id)
        defer { heartbeatBatch.applying.remove(bot.id) }
        let problem = await writeHeartbeat(plan, to: bot)
        heartbeatBatch.problems[bot.id] = problem
        if problem == nil { heartbeatSettings.plans[bot.id.uuidString] = plan; save() }
        return problem
    }

    private func writeHeartbeat(_ plan: HeartbeatPlan, to bot: Bot) async -> String? {
        if let problem = await ensureBotChat(bot) { return problem }
        let client: HermesJobsClient
        do { client = try jobsClient(for: bot) } catch { return error.localizedDescription }
        let jobs: [HermesJob]
        do { jobs = try await client.list() } catch { return BotInfoCache.describe(error, key: client.backend.apiKey) }
        routines.update(bot.id) { $0.jobs = .loaded(jobs) }
        let schedule = plan.cron(stagger: heartbeatStagger(for: bot), localOffset: heartbeatLocalOffset, boxOffset: Self.boxOffset(jobs))
        let delivery = HeartbeatPlan.delivery(profile(of: bot))
        let existing = Self.heartbeatJob(in: jobs, profile: profile(of: bot))
        let problem = await performRoutineAction(bot, token: existing?.id ?? RoutinesCache.newJobToken) { client in
            var job: HermesJob
            if let existing {
                job = existing
                if existing.schedule != schedule || existing.prompt != plan.prompt || existing.deliver != delivery {
                    job = try await client.update(existing.id, schedule: existing.schedule == schedule ? nil : schedule, prompt: existing.prompt == plan.prompt ? nil : plan.prompt,
                                                  deliver: existing.deliver == delivery ? nil : delivery)
                }
                if job.isPaused { job = try await client.resume(job.id) }
            } else {
                job = try await client.create(name: HeartbeatPlan.jobName, schedule: schedule, prompt: plan.prompt, deliver: delivery)
                self.recordSeen(job, on: bot)
            }
            self.routines.replaceJob(job, botID: bot.id)
        }
        if problem == nil { heartbeatSettings.schedules[bot.id.uuidString] = schedule }
        return problem
    }

    /// "Apply to…": one batch over the chosen bots, each with `plan` (nil: its own plan, else the template). The summary
    /// line names the bots it could not set up.
    @discardableResult func applyHeartbeats(_ plan: HeartbeatPlan?, to targets: [Bot]) async -> [UUID: String] {
        heartbeatBatch.summary = nil
        var problems: [UUID: String] = [:]
        for bot in targets where bot.backend == .hermes && !bot.isReadOnlyArchive {
            if let problem = await applyHeartbeat(plan ?? heartbeatSettings.plan(for: bot.id), to: bot) { problems[bot.id] = problem }
        }
        let failed = targets.filter { problems[$0.id] != nil }.map(\.name)
        heartbeatBatch.summary = failed.isEmpty ? "Heartbeat set for \(targets.count) \(targets.count == 1 ? "bot" : "bots")." : "Not set for \(failed.joined(separator: ", ")); see each row."
        return problems
    }

    func setHeartbeat(_ bot: Bot, enabled: Bool) async -> String? {
        guard let job = heartbeatJob(for: bot) else { return HeartbeatCopy.none(bot.name) }
        return await performRoutineAction(bot, token: job.id) { client in
            self.routines.replaceJob(enabled ? try await client.resume(job.id) : try await client.pause(job.id), botID: bot.id)
        }
    }

    /// SwarmHub's own routine is deleted; an adopted one (the bot's own) is only paused.
    func stopHeartbeat(_ bot: Bot) async -> String? {
        guard let job = heartbeatJob(for: bot) else { return HeartbeatCopy.none(bot.name) }
        let error: String?
        if job.name == HeartbeatPlan.jobName {
            error = await performRoutineAction(bot, token: job.id) { client in
                do { try await client.delete(job.id) } catch HermesJobsError.notFound {}
                self.routines.removeJob(job.id, botID: bot.id); bot.routineRunMarks[job.id] = nil
            }
        } else { error = job.isPaused ? nil : await setHeartbeat(bot, enabled: false) }
        if error == nil { heartbeatSettings.plans[bot.id.uuidString] = nil; heartbeatSettings.schedules[bot.id.uuidString] = nil; save() }
        return error
    }

    // MARK: Command and status

    /// The command runs against the box, so it answers in a line once the box did; the task is returned for tests.
    @discardableResult func heartbeatCommand(_ arguments: String, bot: Bot, conversation: any Conversation) -> Task<Void, Never> {
        Task {
            if routines.state(for: bot.id).jobs.value == nil { await refreshRoutines(for: bot) }
            let job = heartbeatJob(for: bot)
            switch arguments.trimmingCharacters(in: .whitespaces).lowercased() {
            case "", "status": commandLine(heartbeatSummary(for: bot).map { "\($0)\nPrompt: \(job?.prompt ?? "")" } ?? HeartbeatCopy.none(bot.name), in: conversation)
            case "pause":
                guard let job, !job.isPaused else { commandLine("No running heartbeat to pause.", in: conversation); return }
                commandLine(await setHeartbeat(bot, enabled: false) ?? "Heartbeat paused.", in: conversation)
            case "resume":
                guard let job, job.isPaused else { commandLine("No paused heartbeat to resume.", in: conversation); return }
                commandLine(await setHeartbeat(bot, enabled: true) ?? "Heartbeat resumed.", in: conversation)
            case "stop":
                guard let job else { commandLine(HeartbeatCopy.none(bot.name), in: conversation); return }
                let adopted = job.name != HeartbeatPlan.jobName
                commandLine(await stopHeartbeat(bot) ?? (adopted ? "Heartbeat stopped: \(job.name) is \(bot.name)'s own routine, so it is paused, not deleted." : "Heartbeat stopped."), in: conversation)
            default:
                guard case .success(let plan) = HeartbeatPlan.parse(arguments) else { commandLine(HeartbeatCopy.usage, in: conversation); return }
                let wakes = plan.wakesPerDay(stagger: heartbeatStagger(for: bot))
                commandLine(await applyHeartbeat(plan, to: bot) ?? HeartbeatCopy.started(bot.name, plan: plan, wakes: wakes, replaced: job != nil), in: conversation)
            }
        }
    }

    /// "Heartbeat · hourly 08–23 · on · next 14:07 · last ok · silent".
    func heartbeatSummary(for bot: Bot) -> String? {
        guard let job = heartbeatJob(for: bot) else { return nil }
        return ChipText.line(["Heartbeat", heartbeatLabel(job, bot: bot), job.isPaused ? "paused" : "on", job.isPaused ? nil : heartbeatNextRun(job).map { "next " + $0 },
                             heartbeatLastResult(job, bot: bot).map { "last " + $0 }])
    }

    /// The chat's heartbeat bar: "Heartbeat · hourly 08–23 · next 14:07" (paused: "… · paused"; no next run known: "… · on").
    func heartbeatBar(_ job: HermesJob, bot: Bot) -> String {
        ChipText.line(["Heartbeat", heartbeatLabel(job, bot: bot), job.isPaused ? "paused" : heartbeatNextRun(job).map { "next " + $0 } ?? "on"])
    }

    /// The plan's label while the box runs it; the box's own schedule once it was changed there (P56), in Mac time when regular.
    func heartbeatLabel(_ job: HermesJob, bot: Bot) -> String {
        guard heartbeatBoxChange(for: bot) != nil else { return heartbeatSettings.plans[bot.id.uuidString]?.label ?? job.scheduleDisplay }
        return boxHeartbeatLabel(job.schedule, jobs: routines.state(for: bot.id).jobs.value ?? []) ?? job.scheduleDisplay
    }

    /// "14:07" in the Mac's time.
    func heartbeatNextRun(_ job: HermesJob) -> String? {
        guard let date = job.nextRunAt.flatMap(RoutineTime.date) else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = heartbeatTimeZone; formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "ok · silent" (answered `[SILENT]`), "ok", or the error.
    func heartbeatLastResult(_ job: HermesJob, bot: Bot) -> String? {
        guard let run = job.lastRunAt else { return nil }
        if job.lastStatus == "error" { return "error" + (job.lastError.map { ": \($0)" } ?? "") }
        return Self.sameRoutineRun(routines.state(for: bot.id).silentRuns[job.id], run) ? "ok · silent" : (job.lastStatus ?? "ok")
    }
}

extension ChatMessage {
    /// A delivered heartbeat (or routine) row and its reply, hidden because the reply was `[SILENT]`.
    var isSilentHeartbeat: Bool { metadata[AutomationKey.silent] != nil }
}
