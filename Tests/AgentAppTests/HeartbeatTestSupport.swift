import Foundation
@testable import AgentApp

// P46: a Hermes jobs table on a SessionServer host (shapes as `RoutinesTestSupport.swift`), recording every write, and a
// store whose bots each have a main session on their own synthetic box. No network beyond the in-process protocol.

final class CronTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [[String: Any]] = []
    private var log: [String] = []
    private var counter = 0

    func with<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var jobs: [[String: Any]] { with { table } }
    /// "POST swarmhub-heartbeat", "PATCH <id> deliver,schedule", "pause <id>", "resume <id>", "DELETE <id>".
    var writes: [String] { with { log } }
    func add(_ job: [String: Any]) { with { table.append(job) } }
    func set(_ id: String, _ fields: [String: Any]) { with { if let index = table.firstIndex(where: { $0["id"] as? String == id }) { table[index].merge(fields) { $1 } } } }
    func job(named name: String) -> [String: Any]? { jobs.first { $0["name"] as? String == name } }

    func attach(to state: SessionServer.State) {
        state.with { $0.extraRoute = { [self] method, parts, _, body in route(method, parts, body) } }
    }

    private func route(_ method: String, _ parts: [String], _ body: [String: Any]?) -> (Int, Any)? {
        guard parts.count >= 2, parts[0] == "api", parts[1] == "jobs" else { return nil }
        return with { () -> (Int, Any) in
            if parts.count == 2 {
                if method == "GET" { return (200, ["jobs": table]) }
                counter += 1
                var job = jobPayload(id: String(format: "%012x", 0xbeef00 + counter), name: body?["name"] as? String ?? "", schedule: body?["schedule"] as? String ?? "",
                                     prompt: body?["prompt"] as? String ?? "")
                job["deliver"] = body?["deliver"] ?? "local"
                table.append(job); log.append("POST \(job["name"] as? String ?? "")")
                return (200, ["job": job])
            }
            let id = parts[2]
            guard let index = table.firstIndex(where: { $0["id"] as? String == id }) else { return (404, ["error": "Job not found"]) }
            switch (method, parts.count == 4 ? parts[3] : "") {
            case ("GET", ""): return (200, ["job": table[index]])
            case ("PATCH", ""):
                var fields = body ?? [:]
                if let schedule = fields["schedule"] as? String { fields["schedule"] = ["kind": "cron", "expr": schedule, "display": schedule]; fields["schedule_display"] = schedule }
                table[index].merge(fields) { $1 }; log.append("PATCH \(id) \((body ?? [:]).keys.sorted().joined(separator: ","))")
                return (200, ["job": table[index]])
            case ("DELETE", ""): table.remove(at: index); log.append("DELETE \(id)"); return (200, ["ok": true])
            case ("POST", "pause"): table[index].merge(["enabled": false, "state": "paused"]) { $1 }; log.append("pause \(id)"); return (200, ["job": table[index]])
            case ("POST", "resume"): table[index].merge(["enabled": true, "state": "scheduled"]) { $1 }; log.append("resume \(id)"); return (200, ["job": table[index]])
            default: return (405, ["error": "method not allowed"])
            }
        }
    }
}

/// Bots with one paired exchange in their main session (`s-<name>`), each box with a jobs table.
@MainActor func heartbeatStore(bots names: [String], url: URL = temporaryStore()) -> (AppStore, [Bot], [SessionServer.State], [CronTable]) {
    let (store, bots, states) = reconcileStore(bots: names, url: url)
    var tables: [CronTable] = []
    for (bot, state) in zip(bots, states) {
        let session = "s-\(bot.name.lowercased())", time = Date().addingTimeInterval(-600)
        bot.hermesSessionID = session
        bot.messages = [ChatMessage(role: .user, content: "hello", createdAt: time), ChatMessage(role: .assistant, content: "hi there", createdAt: time.addingTimeInterval(2), turnState: .finished)]
        state.add(session, "user", "hello", time: time.timeIntervalSince1970); state.add(session, "assistant", "hi there", finish: "stop", time: time.timeIntervalSince1970 + 2)
        let table = CronTable(); table.attach(to: state); tables.append(table)
    }
    store.heartbeatTimeZone = TimeZone(identifier: "Europe/Warsaw")!
    store.now = { Date(timeIntervalSince1970: 1_792_051_200) } // 2026-10-15 08:00 UTC, CEST (+02:00)
    return (store, bots, states, tables)
}

/// The box delivering a routine's output to the Bot Chat and the bot's reply (`cron/scheduler_delivery.py`).
func deliverToBotChat(_ state: SessionServer.State, session: String, job: String, output: String, reply: String) {
    state.add(session, "user", "[Cronjob \"\(job)\" output — scheduled job, not the user. Reply in this chat if it needs Konrad.]\n\(output)")
    state.add(session, "assistant", reply, finish: "stop")
}

func requests(_ state: SessionServer.State, _ method: String, _ prefix: String) -> [SessionServer.Logged] {
    state.log.all.filter { $0.method == method && $0.path.hasPrefix(prefix) }
}
