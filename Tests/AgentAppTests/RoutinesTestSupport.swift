import Foundation
@testable import AgentApp

// Synthetic Hermes jobs server. Shapes follow `gateway/platforms/api_server.py` (v2026.8.19) `_handle_*_job`
// and `cron/jobs.py` `create_job`; cron sessions follow `cron/scheduler.py` (`cron_<id>_<stamp>`, "<name> · <time>").

func jobPayload(id: String, name: String, schedule: String = "0 9 * * *", prompt: String = "Summarise the inbox", enabled: Bool = true,
                lastRunAt: String? = nil, lastStatus: String? = nil, lastError: String? = nil) -> [String: Any] {
    ["id": id, "name": name, "prompt": prompt, "skills": [String](), "skill": NSNull(),
     "schedule": ["kind": "cron", "expr": schedule, "display": schedule], "schedule_display": schedule,
     "repeat": ["times": NSNull(), "completed": 0], "enabled": enabled, "state": enabled ? "scheduled" : "paused",
     "paused_at": enabled ? NSNull() : "2026-10-13T08:00:00+02:00" as Any, "created_at": "2026-10-01T10:00:00.000001+02:00",
     "next_run_at": "2026-10-14T09:00:00.123456+02:00", "last_run_at": lastRunAt ?? NSNull() as Any,
     "last_status": lastStatus ?? NSNull() as Any, "last_error": lastError ?? NSNull() as Any,
     "deliver": "local", "origin": NSNull(), "latest_execution": NSNull()]
}

func jsonBody(_ request: URLRequest) -> [String: Any]? {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

final class FakeJobsServer: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [[String: Any]] = []
    private var sessions: [[String: Any]] = []
    private var messages: [String: [[String: Any]]] = [:]
    private var counter = 0
    var listStatus = 200, createStatus = 200, pauseStatus = 200
    let profile: String

    init(profile: String = "grok-jarvis") { self.profile = profile }

    func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func add(_ job: [String: Any]) { withLock { jobs.append(job) } }
    func set(_ id: String, _ fields: [String: Any]) { withLock { if let i = jobs.firstIndex(where: { $0["id"] as? String == id }) { jobs[i].merge(fields) { $1 } } } }
    func job(_ id: String) -> [String: Any]? { withLock { jobs.first { $0["id"] as? String == id } } }
    var jobIDs: [String] { withLock { jobs.compactMap { $0["id"] as? String } } }
    /// Records a finished run: the job's `last_run_at`/`last_status` and a cron session with the reply.
    func finishRun(_ id: String, at stamp: String, sessionStarted: Double, reply: String, status: String = "ok", error: String? = nil) {
        set(id, ["last_run_at": stamp, "last_status": status, "last_error": error ?? NSNull() as Any])
        withLock {
            let name = jobs.first { $0["id"] as? String == id }?["name"] as? String ?? id
            let session = "cron_\(id)_\(Int(sessionStarted))"
            sessions.insert(["id": session, "source": "cron", "title": "\(name) · Oct 13 09:00", "started_at": sessionStarted, "message_count": 2], at: 0)
            messages[session] = [["id": 1, "session_id": session, "role": "user", "content": "prompt", "timestamp": sessionStarted],
                                 ["id": 2, "session_id": session, "role": "assistant", "content": reply, "timestamp": sessionStarted + 5]]
        }
    }

    func handle(_ request: URLRequest) -> (Int, Any) {
        let url = request.url!
        let prefix = "/p/\(profile)/"
        guard url.path.hasPrefix(prefix) else { return (404, ["error": "no route"]) }
        let parts = url.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        return withLock { () -> (Int, Any) in
            switch (method, parts.count, parts.first) {
            case ("GET", 2, "api") where parts[1] == "jobs":
                guard listStatus == 200 else { return (listStatus, ["error": "404: Not Found"]) }
                let all = (url.query ?? "").contains("include_disabled=true")
                return (200, ["jobs": jobs.filter { all || ($0["enabled"] as? Bool ?? true) }])
            case ("POST", 2, "api") where parts[1] == "jobs":
                let body = jsonBody(request) ?? [:]
                counter += 1
                let id = String(format: "%012x", 0xabc000 + counter)
                let job = jobPayload(id: id, name: body["name"] as? String ?? "", schedule: body["schedule"] as? String ?? "", prompt: body["prompt"] as? String ?? "")
                jobs.append(job)
                if createStatus == 424 {
                    return (424, ["error": "Cron job '\(id)' was saved, but its first scheduler registration failed (RuntimeError).", "job_id": id, "job_saved": true, "scheduler_registered": false, "retry_create": false])
                }
                return (200, ["job": job])
            case (_, 3, "api") where parts[1] == "jobs", (_, 4, "api") where parts[1] == "jobs":
                let id = parts[2]
                guard let index = jobs.firstIndex(where: { $0["id"] as? String == id }) else { return (404, ["error": "Job not found"]) }
                switch (method, parts.count == 4 ? parts[3] : "") {
                case ("GET", ""): return (200, ["job": jobs[index]])
                case ("PATCH", ""):
                    var fields = jsonBody(request) ?? [:]  // Hermes parses a schedule text back into its object, as on create.
                    if let schedule = fields["schedule"] as? String { fields["schedule"] = ["kind": "cron", "expr": schedule, "display": schedule]; fields["schedule_display"] = schedule }
                    jobs[index].merge(fields) { $1 }; return (200, ["job": jobs[index]])
                case ("DELETE", ""): jobs.remove(at: index); return (200, ["ok": true])
                case ("POST", "pause"):
                    guard pauseStatus == 200 else { return (pauseStatus, ["error": "pause failed"]) }
                    jobs[index].merge(["enabled": false, "state": "paused"]) { $1 }; return (200, ["job": jobs[index]])
                case ("POST", "resume"): jobs[index].merge(["enabled": true, "state": "scheduled"]) { $1 }; return (200, ["job": jobs[index]])
                case ("POST", "run"): jobs[index].merge(["enabled": true, "state": "scheduled", "next_run_at": "2026-10-13T09:00:00+02:00"]) { $1 }; return (200, ["job": jobs[index]])
                default: return (405, ["error": "method not allowed"])
                }
            case ("GET", 2, "api") where parts[1] == "sessions":
                let cronOnly = (url.query ?? "").contains("source=cron")
                return (200, ["object": "list", "data": sessions.filter { !cronOnly || $0["source"] as? String == "cron" }])
            case ("GET", 4, "api") where parts[1] == "sessions" && parts[3] == "messages":
                return (200, ["object": "list", "session_id": parts[2], "data": messages[parts[2]] ?? []])
            default: return (404, ["error": "no route"])
            }
        }
    }
}

@MainActor func routinesStore(_ server: FakeJobsServer, url: URL? = nil) -> (AppStore, Bot, String) {
    let (host, session) = MockHermesProtocol.serve { server.handle($0) }
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: url ?? temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes": "default-key", "hermes.grok-jarvis": "jarvis-key"]), defaults: defaults, hermesSession: session)
    let bot = Bot(name: "Jarvis", backend: .hermes, hermesProfile: server.profile)
    store.bots = [bot]; store.save()
    return (store, bot, host)
}

/// "METHOD /path?query" for each recorded request.
func requestLines(_ host: String) -> [String] {
    MockHermesProtocol.recorded(host).map { request in
        let url = request.url!
        return "\(request.httpMethod ?? "GET") \(url.path)" + (url.query.map { "?\($0)" } ?? "")
    }
}
