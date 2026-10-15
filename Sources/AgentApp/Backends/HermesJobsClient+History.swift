import Foundation

/// P38: every run of a job finished after a cursor, oldest first, for routine catch-up (the delivery is part D). Matched
/// by the job's stable cron session id `cron_<job id>_…`, never by title, so two equally named jobs cannot take each
/// other's results. GET only. An unfinished output or more than 2,000 cron sessions throws, so a caller never advances
/// its cursor past a run it did not read.
extension HermesJobsClient {
    static let historyPageSize = 100, historyPages = 20

    func completedRuns(for job: HermesJob, after cursor: String, now: Date = .now) async throws -> [(stamp: String, result: HermesRunResult)] {
        let since = RoutineTime.date(cursor) ?? .distantPast
        let until = job.lastRunAt.flatMap(RoutineTime.date) ?? now
        var sessions: [[String: Any]] = []; var seen = Set<String>()
        for page in 0..<Self.historyPages {
            let json = try await backend.jsonRequest(path: "api/sessions?source=cron&limit=\(Self.historyPageSize)&offset=\(page * Self.historyPageSize)")
            guard let rows = json["data"] as? [[String: Any]] else { throw HermesJobsError.invalidResponse }
            for row in rows {
                guard let id = row["id"] as? String, seen.insert(id).inserted, id.hasPrefix("cron_\(job.id)_"),
                      let date = SessionUsage.date(row["ended_at"]) ?? SessionUsage.date(row["started_at"]),
                      date > since, date <= until.addingTimeInterval(60), row["ended_at"] != nil || date <= until else { continue }
                sessions.append(row)
            }
            if rows.count < Self.historyPageSize { break }
            if page == Self.historyPages - 1 { throw BackendError.unavailable("Routine history exceeded the 2,000-session catch-up limit. No cursor was advanced.") }
        }
        var results: [(String, HermesRunResult)] = []
        let started = { (row: [String: Any]) in SessionUsage.date(row["started_at"]) ?? .distantPast }
        for row in sessions.sorted(by: { started($0) < started($1) }) {
            guard let id = row["id"] as? String else { continue }
            let json = try await backend.jsonRequest(path: "api/sessions/\(HermesBackend.escapedPath(id))/messages?order=oldest&limit=500&offset=0")
            guard let messages = json["data"] as? [[String: Any]], messages.count < 500 else { throw HermesJobsError.invalidResponse }
            let text = messages.filter { $0["role"] as? String == "assistant" }.compactMap { HermesBackend.normalizedContent($0["content"]) }.joined(separator: "\n\n")
            guard !text.isEmpty || job.lastStatus == "error" else { throw BackendError.unavailable("A routine output is not available yet; it will be retried.") }
            let stamp = ISO8601DateFormatter().string(from: SessionUsage.date(row["ended_at"]) ?? SessionUsage.date(row["started_at"]) ?? until)
            results.append((stamp, .init(sessionID: id, text: text, status: row["status"] as? String, error: row["error"] as? String)))
        }
        return results
    }
}
