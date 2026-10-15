import Foundation

/// P43: a routine that runs shows it. Run now marks the row Running… at the click; SwarmHub then reads that bot's jobs
/// every 5 s until the job's `last_run_at` moves (at most 30 min), so the result card arrives right away instead of on
/// the 60 s inbox gate. A bot's cron tool step refreshes its routines as soon as the step ends.
enum RoutineWatch {
    static let interval: Duration = .seconds(5)
    static let maximumChecks = 360 // 30 min of 5 s checks

    /// Hermes's cron tool (`cronjob`, older `schedule_cronjob` / `list_cronjobs` / `remove_cronjob`).
    static func isCronTool(_ name: String) -> Bool { name.lowercased().contains("cron") }

    /// Running per the server: `state` running, a fire claim, or a manual run newer than the last finished one.
    static func serverSaysRunning(_ job: HermesJob) -> Bool {
        if job.state == "running" || job.fireClaimed { return true }
        guard let manual = job.manualRunAt else { return false }
        guard let last = job.lastRunAt else { return true }
        return RoutineTime.isLater(manual, than: last)
    }

    /// The row shows Running… and its Run now button is off.
    static func isRunning(_ job: HermesJob, in state: BotRoutinesState) -> Bool { state.running[job.id] != nil || serverSaysRunning(job) }
}

extension AppStore {
    static func routineWatchKey(_ bot: Bot, _ jobID: String) -> String { "\(bot.id.uuidString)|\(jobID)" }

    /// Run now: Running… at once, the run request, then the 5 s watch. A second click while it runs does nothing.
    func runRoutineNow(_ job: HermesJob, for bot: Bot) async {
        guard !RoutineWatch.isRunning(job, in: routines.state(for: bot.id)) else { return }
        routines.update(bot.id) { $0.running[job.id] = now() }
        // The run's card needs the job's previous run as its baseline.
        if bot.routineRunMarks[job.id] == nil { bot.routineRunMarks[job.id] = job.lastRunAt ?? ""; save() }
        let error = await startRoutineRun(job, for: bot)
        guard error == nil else { routines.update(bot.id) { $0.running[job.id] = nil }; return }
        watchRoutineRun(job.id, since: job.lastRunAt, bot: bot)
    }

    /// Starts the watch of one job's run (once per job); it ends when `last_run_at` moves past `since`, the job is gone, or
    /// after 30 min. Only in the app (`routines.autoLoad`); tests switch it on with an injected sleep.
    func watchRoutineRun(_ jobID: String, since: String?, bot: Bot) {
        let key = Self.routineWatchKey(bot, jobID)
        guard routines.autoLoad, routines.watches[key] == nil else { return }
        let sleep = routineWatchSleep
        watchRoutineSession(jobID, since: since, bot: bot)
        routines.watches[key] = Task { [weak self] in
            await self?.followRoutineRun(jobID, since: since, bot: bot, sleep: sleep)
            self?.routines.watches[key] = nil
            self?.routines.update(bot.id) { $0.running[jobID] = nil }
        }
    }

    private func followRoutineRun(_ jobID: String, since: String?, bot: Bot, sleep: @Sendable (Duration) async throws -> Void) async {
        for _ in 0..<RoutineWatch.maximumChecks {
            do { try await sleep(RoutineWatch.interval) } catch { return }
            guard !Task.isCancelled else { return }
            await refreshRoutines(for: bot)
            guard let jobs = routines.state(for: bot.id).jobs.value else { continue }
            guard let job = jobs.first(where: { $0.id == jobID }) else { return }
            if let last = job.lastRunAt, last != since, since.map({ RoutineTime.isLater(last, than: $0) }) ?? true { return }
        }
    }

    /// P42 8: a run in progress is a wake: its `cron_<job>_<time>` session (source `cron`, started after the previous run
    /// ended, else in the last 30 min) shows live in the bot's chat, "Woken by: routine <name>"; P43's card stays the end.
    func watchRoutineSession(_ jobID: String, since: String?, bot: Bot) {
        let name = routines.state(for: bot.id).jobs.value?.first { $0.id == jobID }?.name ?? jobID
        let after = since.flatMap(RoutineTime.date).map { $0.addingTimeInterval(1) } ?? now().addingTimeInterval(-BotWorkSchedule.recent)
        watchBotWork(bot, target: .newest(source: "cron", prefix: "cron_\(jobID)_", after: after), origin: .routine(name))
    }

    /// Jobs the server reports running get the same quick watch (a scheduled run, or one a bot started).
    func watchRunningRoutines(_ jobs: [HermesJob], bot: Bot) {
        for job in jobs where RoutineWatch.serverSaysRunning(job) { watchRoutineRun(job.id, since: job.lastRunAt, bot: bot) }
    }

    /// A cron tool step ended in this bot's turn: its routines are read now (the Routines tab updates live).
    func routineToolEnded(bot: Bot) {
        guard routines.autoLoad, bot.backend == .hermes, !routines.toolRefreshes.contains(bot.id) else { return }
        routines.toolRefreshes.insert(bot.id)
        Task { [weak self] in
            await self?.refreshRoutines(for: bot)
            self?.routines.toolRefreshes.remove(bot.id)
        }
    }

    /// The whole output of a routine run (every assistant message of its cron session), for the card's Open result.
    func routineFullResult(sessionID: String, bot: Bot) async throws -> String {
        try await jobsClient(for: bot).fullOutput(sessionID: sessionID)
    }
}

extension HermesJobsClient {
    /// `GET api/sessions/{id}/messages`: the run's assistant messages, oldest first, joined.
    func fullOutput(sessionID: String) async throws -> String {
        let json = try await backend.jsonRequest(path: "api/sessions/\(HermesBackend.escapedPath(sessionID))/messages?order=oldest&limit=500&offset=0")
        guard let rows = json["data"] as? [[String: Any]] else { throw HermesJobsError.invalidResponse }
        return rows.filter { $0["role"] as? String == "assistant" }
            .compactMap { HermesBackend.normalizedContent($0["content"])?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
