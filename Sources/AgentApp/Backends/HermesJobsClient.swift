import Foundation

// Shapes follow Hermes `gateway/platforms/api_server.py` (v2026.8.19) `_handle_*_job` handlers and
// `cron/jobs.py` (`create_job` job dict, `_normalize_job_record`, `effective_job_state`).

/// One Hermes cron job (`/api/jobs`), i.e. one routine of a bot.
struct HermesJob: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var prompt: String
    /// Text the server accepts back as `schedule`: the cron expression, `every <N>m`, or the one-shot timestamp.
    var schedule: String
    /// `cron`, `interval` or `once` (from the parsed `schedule` object).
    var scheduleKind: String?
    var scheduleDisplay: String
    var enabled: Bool
    /// `scheduled`, `paused`, `running`, `completed` or `error` (derived from `enabled` by Hermes).
    var state: String
    var nextRunAt: String?
    var lastRunAt: String?
    var lastStatus: String?
    var lastError: String?
    /// P43: when Run now asked for a run (`manual_run_at`) and whether a scheduler has claimed the fire (`fire_claim`).
    var manualRunAt: String? = nil
    var fireClaimed = false
    /// P46: where the output goes: `local` (kept on the box) or `bot-chat:<profile>` (a turn in that bot's Bot Chat).
    var deliver: String? = nil
    /// Runs Hermes has recorded (`repeat.completed`, bumped by `mark_job_run` after the run's delivery).
    var runsCompleted: Int? = nil
    /// A run is in flight: Hermes says `running`, or a scheduler holds the fire claim. Pausing does not stop it.
    var isRunning: Bool { state == "running" || fireClaimed }

    var isPaused: Bool { !enabled || state == "paused" }

    static func parse(_ row: [String: Any]) -> HermesJob? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let display = text(row["schedule_display"]) ?? ""
        var schedule = display, kind: String?
        if let object = row["schedule"] as? [String: Any] {
            kind = object["kind"] as? String
            switch kind {
            case "cron": schedule = text(object["expr"]) ?? display
            case "interval": if let minutes = object["minutes"] as? Int { schedule = "every \(minutes)m" }
            case "once": schedule = text(object["run_at"]) ?? display
            default: schedule = text(object["display"]) ?? display
            }
        } else if let raw = text(row["schedule"]) { schedule = raw }
        let enabled = row["enabled"] as? Bool ?? true
        return .init(id: id, name: text(row["name"]) ?? id, prompt: row["prompt"] as? String ?? "", schedule: schedule, scheduleKind: kind,
                     scheduleDisplay: display.isEmpty ? schedule : display, enabled: enabled,
                     state: text(row["state"]) ?? (enabled ? "scheduled" : "paused"), nextRunAt: text(row["next_run_at"]),
                     lastRunAt: text(row["last_run_at"]), lastStatus: text(row["last_status"]), lastError: text(row["last_error"]),
                     manualRunAt: text(row["manual_run_at"]), fireClaimed: row["fire_claim"].map { !($0 is NSNull) && ($0 as? Bool) != false } ?? false,
                     deliver: text(row["deliver"]), runsCompleted: (row["repeat"] as? [String: Any])?["completed"] as? Int)
    }

    static func parseList(_ json: [String: Any]) -> [HermesJob] { ((json["jobs"] as? [[String: Any]]) ?? []).compactMap(parse) }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Job ids are 12 lowercase hex characters (`_JOB_ID_RE`); anything else is never put into a URL.
    static func isValidID(_ id: String) -> Bool { id.count == 12 && id.allSatisfy { "0123456789abcdef".contains($0) } }
}

/// The output of one finished run: the cron session's last assistant message.
/// P38: `status` and `error` of the run's session row, when read through `completedRuns`.
struct HermesRunResult: Equatable, Sendable { let sessionID: String; let text: String; var status: String? = nil; var error: String? = nil }

enum HermesJobsError: LocalizedError, Equatable {
    /// `/api/jobs` is absent (404/405) or the server has no cron module (501).
    case noJobsAPI
    /// HTTP 424: the job was saved but not registered with the scheduler (`CronSchedulerRegistrationError.to_dict`).
    case schedulerUnavailable(jobID: String?)
    case invalidJobID(String)
    case notFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noJobsAPI: "This Hermes server has no jobs API."
        case .schedulerUnavailable: "Hermes saved the routine, but its scheduler is unavailable right now (HTTP 424). Don't create it again — pause and resume or edit it later to retry."
        case .invalidJobID(let id): "Invalid routine id \(id)."
        case .notFound: "This routine no longer exists on the server."
        case .invalidResponse: "Hermes returned an unexpected jobs response."
        }
    }
}

/// `/api/jobs*` for one bot, via that bot's `/p/<profile>` prefix and key (all requests go through `HermesBackend`).
struct HermesJobsClient: Sendable {
    let backend: HermesBackend

    /// Identifies the server + profile, so bots sharing a profile are polled once.
    var identity: String { "\(backend.baseURL.absoluteString)|\(backend.profile)" }

    /// Paused jobs are disabled, which `GET /api/jobs` hides unless `include_disabled` is set. The routines SwarmHub keeps
    /// for itself (the presence lease, loops and goals handed to the box while it is closed) are not the user's: left out.
    func list() async throws -> [HermesJob] { try await listAll().filter { !PresenceLease.isInternal($0.name) } }

    func listAll() async throws -> [HermesJob] {
        do { return HermesJob.parseList(try await backend.jsonRequest(path: "api/jobs?include_disabled=true")) }
        catch BackendError.http(let code, _) where [404, 405, 501].contains(code) { throw HermesJobsError.noJobsAPI }
    }

    func get(_ id: String) async throws -> HermesJob { try await job(path: "api/jobs/\(try checked(id))") }

    /// `deliver: "local"` keeps the output on the box; the app reads it from the run's session. P46: a heartbeat passes
    /// `bot-chat:<profile>`.
    /// `repeat`: run at most that many times (Hermes `create_job`; nil runs until stopped).
    func create(name: String, schedule: String, prompt: String, deliver: String = "local", repeat times: Int? = nil) async throws -> HermesJob {
        var body: [String: Any] = ["name": name, "schedule": schedule, "prompt": prompt, "deliver": deliver]
        if let times { body["repeat"] = times }
        let (data, response) = try await backend.rawRequest(path: "api/jobs", method: "POST", body: body)
        if (response as? HTTPURLResponse)?.statusCode == 424 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw HermesJobsError.schedulerUnavailable(jobID: json?["job_id"] as? String)
        }
        try await mapErrors { try backend.validate(response, data: data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let job = (json["job"] as? [String: Any]).flatMap(HermesJob.parse) else { throw HermesJobsError.invalidResponse }
        return job
    }

    /// PATCH accepts `name, schedule, prompt, deliver, skills, skill, repeat, enabled` (`_UPDATE_ALLOWED_FIELDS`).
    /// Only the given fields are sent.
    func update(_ id: String, name: String? = nil, schedule: String? = nil, prompt: String? = nil, enabled: Bool? = nil, deliver: String? = nil) async throws -> HermesJob {
        var fields: [String: Any] = [:]
        if let deliver { fields["deliver"] = deliver }
        if let name { fields["name"] = name }
        if let schedule { fields["schedule"] = schedule }
        if let prompt { fields["prompt"] = prompt }
        if let enabled { fields["enabled"] = enabled }
        return try await job(path: "api/jobs/\(try checked(id))", method: "PATCH", body: fields)
    }
    func pause(_ id: String) async throws -> HermesJob { try await job(path: "api/jobs/\(try checked(id))/pause", method: "POST", body: [:]) }
    func resume(_ id: String) async throws -> HermesJob { try await job(path: "api/jobs/\(try checked(id))/resume", method: "POST", body: [:]) }
    /// Hermes sets `next_run_at` to now and also re-enables a paused job (`trigger_job`).
    func run(_ id: String) async throws -> HermesJob { try await job(path: "api/jobs/\(try checked(id))/run", method: "POST", body: [:]) }
    func delete(_ id: String) async throws {
        let path = "api/jobs/\(try checked(id))"
        try await mapErrors { _ = try await backend.jsonRequest(path: path, method: "DELETE") }
    }

    /// Finds the session of the job's latest run and returns its last assistant message. The scheduler runs each job in a
    /// session `cron_<job id>_<YYYYmmdd_HHMMSS>` and titles it `<job name> · <Mon dd HH:MM>` (or `cron <job id>`)
    /// — `cron/scheduler.py` `run_job` and `_set_cron_session_title`. Compression may rotate the id, so titles also match.
    func runResult(for job: HermesJob) async throws -> HermesRunResult? {
        let finishedAt = job.lastRunAt.flatMap(RoutineTime.date)
        var session: [String: Any]?
        for query in ["api/sessions?source=cron&limit=50&offset=0", "api/sessions?limit=100&offset=0"] {
            let rows = (try await backend.jsonRequest(path: query)["data"] as? [[String: Any]]) ?? []
            session = Self.latestRunSession(rows, job: job, finishedAt: finishedAt)
            if session != nil { break }
        }
        guard let id = session?["id"] as? String else { return nil }
        let json = try await backend.jsonRequest(path: "api/sessions/\(HermesBackend.escapedPath(id))/messages?order=latest&limit=50")
        let rows = (json["data"] as? [[String: Any]]) ?? []
        let replies = rows.filter { $0["role"] as? String == "assistant" }.compactMap { row -> (Double, String)? in
            guard let text = HermesBackend.normalizedContent(row["content"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return ((row["timestamp"] as? Double) ?? (row["created_at"] as? Double) ?? 0, text)
        }
        // `order=latest` pages may come newest-first or oldest-first; the timestamp decides, else the last row.
        guard let reply = replies.enumerated().max(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) })?.element.1 else { return .init(sessionID: id, text: "") }
        return .init(sessionID: id, text: reply)
    }

    static func latestRunSession(_ rows: [[String: Any]], job: HermesJob, finishedAt: Date?) -> [String: Any]? {
        let base = String(job.name.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60)).trimmingCharacters(in: .whitespaces)
        let matches = GrokServerArchive.excludingArchives(rows).filter { row in
            let id = row["id"] as? String ?? "", title = row["title"] as? String ?? ""
            if id.hasPrefix("cron_\(job.id)_") || title == "cron \(job.id)" || title.hasPrefix("cron \(job.id) ") { return true }
            return !base.isEmpty && (row["source"] as? String ?? "cron") == "cron" && title.hasPrefix("\(base) · ")
        }
        func started(_ row: [String: Any]) -> Double { (row["started_at"] as? Double) ?? Double(row["started_at"] as? Int ?? 0) }
        // A run that started after this job's `last_run_at` belongs to a later run that has not finished yet.
        let finished = finishedAt.map { limit in matches.filter { started($0) == 0 || started($0) <= limit.timeIntervalSince1970 + 60 } } ?? matches
        return finished.max { (started($0), $0["id"] as? String ?? "") < (started($1), $1["id"] as? String ?? "") }
    }

    private func job(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> HermesJob {
        let json = try await mapErrors { try await backend.jsonRequest(path: path, method: method, body: body) }
        guard let job = (json["job"] as? [String: Any]).flatMap(HermesJob.parse) else { throw HermesJobsError.invalidResponse }
        return job
    }

    private func checked(_ id: String) throws -> String {
        guard HermesJob.isValidID(id) else { throw HermesJobsError.invalidJobID(id) }
        return id
    }

    /// Per-job 404 means the job is gone; 424 means the scheduler is unavailable. Other errors keep Hermes's message.
    private func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch BackendError.http(404, let message) where message.contains("Job not found") { throw HermesJobsError.notFound }
        catch BackendError.http(424, _) { throw HermesJobsError.schedulerUnavailable(jobID: nil) }
        catch BackendError.http(let code, _) where code == 405 || code == 501 { throw HermesJobsError.noJobsAPI }
    }
}
