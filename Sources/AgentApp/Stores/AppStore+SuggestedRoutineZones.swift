import Foundation

/// recsfix2 (#13, daylight saving time): Hermes runs every cron of a profile in one zone (its configured `timezone`, else
/// the server's: UTC on our boxes) and a job has no zone of its own (no `CRON_TZ`), so a routine converted with the summer
/// offset would run an hour off the user's time in winter. The app keeps the routines its suggestions made on the time
/// the user said yes to: each time it reads a bot's jobs, a routine whose box schedule is not the one the zones give at
/// its next run is moved (`PATCH`). Only a job still on the schedule the app last gave or saw is moved; one changed since
/// (on the box or in the editor) is the user's, left alone and no longer followed. While the Mac is off across a change,
/// the runs until the app next reads the jobs can still be an hour off.
extension AppStore {
    func followSuggestedRoutineZones(_ jobs: [HermesJob], bot: Bot, client: HermesJobsClient) async {
        guard bot.backend == .hermes else { return }
        let zones = suggestionZones(for: bot)
        for record in suggestionLedger.records where record.botID == bot.id && record.state == .accepted {
            guard let given = record.draft.boxSchedule else { continue }  // 0.6.5's lead gave the Mac's time: not converted.
            let due = zones.boxSchedule(record.draft.schedule)
            guard let job = followedJob(for: record, given: given, due: due, in: jobs) else { continue }
            if CronDays.same(job.schedule, due) {  // On time (moved by another Mac, or made at today's offset): noted.
                if !CronDays.same(given, due) { updateSuggestionRecord(record.id) { $0.draft.boxSchedule = due } }
                continue
            }
            guard let moved = try? await client.update(job.id, schedule: due) else { continue }  // Tried again at the next read.
            routines.replaceJob(moved, botID: bot.id)
            updateSuggestionRecord(record.id) { $0.draft.boxSchedule = due }
        }
    }

    /// The job a yes made, recorded once it is seen: on the schedule the bot was told or the one due now, doing the ask
    /// (the follow-through's test), and no other record's. A recorded job deleted or moved by someone else is let go.
    private func followedJob(for record: BotSuggestionRecord, given: String, due: String, in jobs: [HermesJob]) -> HermesJob? {
        if let id = record.jobID {
            if let job = jobs.first(where: { $0.id == id }), CronDays.same(job.schedule, given) || CronDays.same(job.schedule, due) { return job }
            updateSuggestionRecord(record.id) { $0.jobID = nil; $0.letGo = true }
            return nil
        }
        guard record.letGo != true else { return nil }
        let taken = Set(suggestionLedger.records.compactMap(\.jobID)), asks = [Set(record.stems), AskText.stems(record.draft.prompt)]
        guard let job = jobs.first(where: { job in
            !taken.contains(job.id) && !job.isPaused && (CronDays.same(job.schedule, given) || CronDays.same(job.schedule, due))
                && asks.contains { AskText.covered($0, by: AskText.stems(job.name + "\n" + job.prompt)) }
        }) else { return nil }
        updateSuggestionRecord(record.id) { $0.jobID = job.id; $0.draft.boxSchedule = job.schedule }
        return job
    }

    private func updateSuggestionRecord(_ id: UUID, _ change: (inout BotSuggestionRecord) -> Void) {
        var ledger = suggestionLedger
        guard let index = ledger.records.firstIndex(where: { $0.id == id }) else { return }
        change(&ledger.records[index])
        suggestionLedger = ledger
    }
}
