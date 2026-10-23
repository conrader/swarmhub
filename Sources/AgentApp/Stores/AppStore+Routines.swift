import AppKit
import Foundation

/// Routines are Hermes cron jobs of the bot's profile (`/p/<profile>/api/jobs*`). The server is the source of truth;
/// `bot.routines` only holds routines that are not on the server yet (imported or created before P2).
extension AppStore {
    func jobsClient(for bot: Bot) throws -> HermesJobsClient {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive, let backend = try backend(for: bot) as? HermesBackend else { throw HermesJobsError.noJobsAPI }
        return HermesJobsClient(backend: backend)
    }

    /// Lists the profile's jobs (paused ones included) and turns newly finished runs into chat cards.
    /// Returns `false` on an error worth backing off for; a missing jobs API is not one (the poller skips it).
    @discardableResult func refreshRoutines(for bot: Bot) async -> Bool {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive else { routines.update(bot.id) { $0.jobs = .unavailable("Routines run on a Hermes server.") }; return true }
        guard !needsKey(bot) else { routines.update(bot.id) { $0.jobs = .failed("Add this bot's key to see its routines.") }; return false }
        let client: HermesJobsClient
        do { client = try jobsClient(for: bot) } catch { routines.update(bot.id) { $0.jobs = .failed(error.localizedDescription) }; return false }
        routines.update(bot.id) { $0.isRefreshing = true }
        do {
            let jobs = try await client.list()
            routines.update(bot.id) { $0.jobs = .loaded(jobs); $0.isRefreshing = false; $0.error = nil }
            recordHeartbeatBaseline(jobs, bot: bot)
            watchRunningRoutines(jobs, bot: bot)
            await deliverFinishedRuns(jobs, bot: bot, client: client)
            return true
        } catch HermesJobsError.noJobsAPI {
            routines.update(bot.id) { $0.jobs = .unavailable(HermesJobsError.noJobsAPI.localizedDescription); $0.isRefreshing = false; $0.error = nil }
            return true
        } catch {
            let reason = BotInfoCache.describe(error, key: client.backend.apiKey)
            routines.update(bot.id) { state in
                state.isRefreshing = false
                if state.jobs.value == nil { state.jobs = .failed(reason) } else { state.error = reason }
            }
            return false
        }
    }

    @discardableResult func createRoutine(for bot: Bot, name: String, schedule: String, prompt: String) async -> String? {
        await performRoutineAction(bot, token: RoutinesCache.newJobToken) { client in
            do {
                let job = try await client.create(name: name, schedule: schedule, prompt: prompt)
                self.recordSeen(job, on: bot); self.routines.replaceJob(job, botID: bot.id)
            } catch HermesJobsError.schedulerUnavailable(let id) {
                // The job is saved; show it rather than inviting a duplicate.
                if let id { bot.routineRunMarks[id] = "" }
                await self.refreshRoutines(for: bot)
                throw HermesJobsError.schedulerUnavailable(jobID: id)
            }
        }
    }

    /// Sends only the fields that changed; the list shows the server's answer.
    @discardableResult func updateRoutine(_ job: HermesJob, for bot: Bot, name: String, schedule: String, prompt: String) async -> String? {
        let name = name == job.name ? nil : name, schedule = schedule == job.schedule ? nil : schedule, prompt = prompt == job.prompt ? nil : prompt
        guard name != nil || schedule != nil || prompt != nil else { return nil }
        return await performRoutineAction(bot, token: job.id) { client in
            self.routines.replaceJob(try await client.update(job.id, name: name, schedule: schedule, prompt: prompt), botID: bot.id)
        }
    }

    /// Optimistic: the toggle flips at once, then shows the server's job (or flips back on error).
    func setRoutine(_ job: HermesJob, enabled: Bool, for bot: Bot) async {
        var optimistic = job; optimistic.enabled = enabled; optimistic.state = enabled ? "scheduled" : "paused"
        routines.replaceJob(optimistic, botID: bot.id)
        if routines.repauseAfterRun.contains(Self.runKey(bot, job.id)) { setRepause(false, key: Self.runKey(bot, job.id)) }
        let error = await performRoutineAction(bot, token: job.id) { client in
            self.routines.replaceJob(enabled ? try await client.resume(job.id) : try await client.pause(job.id), botID: bot.id)
        }
        if error != nil, routines.state(for: bot.id).jobs.value?.contains(where: { $0.id == job.id }) == true { routines.replaceJob(job, botID: bot.id) }
    }

    /// Hermes's run endpoint also re-enables a paused job; such a job is paused again once its run is seen.
    /// P43: `runRoutineNow` (`AppStore+RoutineWatch.swift`) wraps this with Running… and the 5 s watch.
    func startRoutineRun(_ job: HermesJob, for bot: Bot) async -> String? {
        await performRoutineAction(bot, token: job.id) { client in
            let started = try await client.run(job.id)
            if job.isPaused { self.setRepause(true, key: Self.runKey(bot, job.id)) }
            self.routines.replaceJob(started, botID: bot.id)
        }
    }

    func deleteRoutine(_ job: HermesJob, for bot: Bot) async {
        let error = await performRoutineAction(bot, token: job.id) { client in
            do { try await client.delete(job.id) } catch HermesJobsError.notFound {}
        }
        guard error == nil else { return }
        routines.removeJob(job.id, botID: bot.id); bot.routineRunMarks[job.id] = nil; save()
    }

    /// Imported routines reach the server only from here, and arrive paused: create, then pause. If the pause fails the
    /// new job is deleted again so an imported routine never runs unasked.
    @discardableResult func createRoutineOnServer(_ routine: BotRoutine, for bot: Bot) async -> String? {
        // A Grok routine has no schedule until set up; it is never sent half-made.
        guard !routine.schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "This routine needs a schedule first." }
        return await performRoutineAction(bot, token: routine.id.uuidString) { client in
            let created: HermesJob
            do { created = try await client.create(name: routine.name, schedule: routine.schedule, prompt: routine.prompt) }
            catch HermesJobsError.schedulerUnavailable(let id?) { created = try await client.get(id) }
            let paused: HermesJob
            do { paused = try await client.pause(created.id) }
            catch { try? await client.delete(created.id); throw error }
            self.recordSeen(paused, on: bot)
            bot.routines.removeAll { $0.id == routine.id }; self.objectWillChange.send(); self.save()
            self.routines.replaceJob(paused, botID: bot.id)
        }
    }

    // MARK: Completion inbox

    /// Polls each Hermes bot's jobs while the app runs (once per server+profile, ≥ 60 s apart, backing off on errors); the
    /// 5 s tick also carries the bot-message list (P42: 5 s while a bot on that connection works, 20 s when idle).
    func startRoutinePolling(tick: Duration = .seconds(5)) {
        guard routines.autoLoad, routinePollTask == nil else { return }
        routinePollTask = Task { [weak self] in
            while !Task.isCancelled, let store = self {
                await store.pollRoutinesOnce()
                await store.reclaimHandoffs()
                await store.renewAlertPresenceIfDue()
                await store.pollBotMessagesOnce()
                await store.pollLiveRowsOnce()
                await store.orientationPassIfDue()
                try? await Task.sleep(for: tick)
            }
        }
    }

    func pollRoutinesOnce(now: Date = .now) async {
        var polled: Set<String> = []
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive && !needsKey(bot) {
            guard routines.state(for: bot.id).hasJobsAPI, let client = try? jobsClient(for: bot),
                  routines.isDue(client.identity, now: now), polled.insert(client.identity).inserted else { continue }
            let ok = await refreshRoutines(for: bot)
            routines.recordPoll(client.identity, success: ok, now: now)
        }
    }

    /// A job's first sighting only records its `last_run_at`; a later, newer value is a finished run and gets one card.
    /// Marks are written before any await, so overlapping refreshes never post the same run twice.
    func deliverFinishedRuns(_ jobs: [HermesJob], bot: Bot, client: HermesJobsClient) async {
        var finished: [(job: HermesJob, seen: String)] = []
        var changed = false
        for job in jobs {
            let current = job.lastRunAt ?? ""
            guard let seen = bot.routineRunMarks[job.id] else { bot.routineRunMarks[job.id] = current; changed = true; continue }
            guard current != seen else { continue }
            bot.routineRunMarks[job.id] = current; changed = true
            if !current.isEmpty, RoutineTime.isLater(current, than: seen) { finished.append((job, seen)) }
        }
        let listed = Set(jobs.map(\.id))
        for id in bot.routineRunMarks.keys where !listed.contains(id) { bot.routineRunMarks[id] = nil; changed = true }
        if changed { save() }
        for entry in finished { await postRoutineCard(entry.job, after: entry.seen, bot: bot, client: client) }
    }

    /// P38 D: runs missed while the app was closed get their cards first (oldest first), then the newest run's card; every
    /// card goes through the ledger (`RoutineDelivery.swift`), so a crash or an overlapping poll never posts a run twice.
    private func postRoutineCard(_ job: HermesJob, after seen: String, bot: Bot, client: HermesJobsClient) async {
        if routines.repauseAfterRun.contains(Self.runKey(bot, job.id)) {
            setRepause(false, key: Self.runKey(bot, job.id))
            if !job.isPaused, let paused = try? await client.pause(job.id) { routines.replaceJob(paused, botID: bot.id) }
        }
        // P46 5: a heartbeat (any `bot-chat:` routine of this bot) answers in the Bot Chat, which the live read shows; only a
        // `[SILENT]` run is noted, for the Routines tab's "ok · silent".
        if deliversToBotChat(job, bot: bot) {
            if let result = try? await client.runResult(for: job), SilentReply.isSilent(result.text) { markSilentRun(job.id, runAt: job.lastRunAt ?? "", bot: bot) }
            return
        }
        let missed = seen.isEmpty ? [] : await catchUpRoutine(job, after: seen, bot: bot, client: client)
        var result: HermesRunResult?, lookupError: String?
        do { result = try await client.runResult(for: job) } catch { lookupError = BotInfoCache.describe(error, key: client.backend.apiKey) }
        do {
            for run in missed where run.result.sessionID != result?.sessionID { try deliverRoutine(run.job, result: run.result, bot: bot, lookupError: nil, notify: false) }
            try deliverRoutine(job, result: result, bot: bot, lookupError: lookupError)
        } catch { routines.update(bot.id) { $0.error = error.localizedDescription } }
    }

    /// "Routine finished" card: name, status, the first ~600 characters of the result and the error, if any.
    static func routineCard(job: HermesJob, result: HermesRunResult?, lookupError: String?) -> ChatMessage {
        let text = result?.text ?? ""
        let content = text.count > 600 ? String(text.prefix(600)) + "…" : text
        var metadata = ["routine": job.name, "status": job.lastStatus ?? "ok", "jobID": job.id, "runAt": job.lastRunAt ?? ""]
        if let error = job.lastError { metadata["error"] = error }
        if let session = result?.sessionID { metadata["sessionID"] = session }
        if result == nil { metadata["note"] = lookupError.map { "Result unavailable: \($0)" } ?? "No run output was found on the server." }
        // P38 D: dated by the run (a caught-up card shows when its run finished, not when it was read).
        return ChatMessage(role: .assistant, content: content, createdAt: job.lastRunAt.flatMap(RoutineTime.date) ?? .now, presentation: .routineResult, metadata: metadata)
    }

    private static func runKey(_ bot: Bot, _ jobID: String) -> String { "\(bot.id.uuidString)|\(jobID)" }

    func recordSeen(_ job: HermesJob, on bot: Bot) { bot.routineRunMarks[job.id] = job.lastRunAt ?? ""; save() }

    @discardableResult func performRoutineAction(_ bot: Bot, token: String, _ body: (HermesJobsClient) async throws -> Void) async -> String? {
        routines.setBusy(token, true, botID: bot.id)
        defer { routines.setBusy(token, false, botID: bot.id) }
        do {
            let client = try jobsClient(for: bot)
            do { try await body(client) }
            catch { throw RoutineActionError(message: BotInfoCache.describe(error, key: client.backend.apiKey), notFound: error as? HermesJobsError == .notFound, jobID: token) }
            routines.update(bot.id) { $0.error = nil }
            return nil
        } catch let failure as RoutineActionError {
            if failure.notFound { routines.removeJob(failure.jobID, botID: bot.id) }
            routines.update(bot.id) { $0.error = failure.message }
            return failure.message
        } catch {
            routines.update(bot.id) { $0.error = error.localizedDescription }
            return error.localizedDescription
        }
    }
}

private struct RoutineActionError: Error { let message: String; let notFound: Bool; let jobID: String }
