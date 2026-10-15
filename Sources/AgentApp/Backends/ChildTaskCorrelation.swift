import CryptoKit
import Foundation

/// P38 D: one identity per delegated child within a stream. A server task id wins (hashed with the stream's session, so
/// the same id is the same card after a reconnect); an event without one is matched to the only waiting start, or the
/// only waiting start with its title. A start the server never names keeps the id it got.
struct ChildTaskCorrelation {
    static let idKeys = ["task_id", "subagent_id", "delegation_id", "child_run_id", "id"]
    var scope = ""
    private var ids: [String: UUID] = [:]
    private var pending: [(title: String, id: UUID)] = []
    init(scope: String = "") { self.scope = scope }

    mutating func event(_ event: String, _ json: [String: Any]) -> SubAgentTask {
        let title = json["task"] as? String ?? json["label"] as? String ?? "Delegated task"
        let serverID = Self.idKeys.lazy.compactMap { json[$0] as? String }.first
        let starting = event == "subagent.start"
        let id: UUID
        if let serverID, let known = ids[serverID] { id = known }
        else if !starting, let index = waitingIndex(title: title) {
            id = pending.remove(at: index).id
            if let serverID { ids[serverID] = id }
        } else if let serverID {
            id = Self.stableID(scope + "|" + serverID); ids[serverID] = id
            if starting { pending.append((title, id)) }
        } else { id = UUID(); if starting { pending.append((title, id)) } }
        if !starting, let serverID, let index = pending.firstIndex(where: { $0.id == ids[serverID] }) { pending.remove(at: index) }
        let status: SubAgentStatus = starting ? .running : (["completed", "success", "done"].contains(json["status"] as? String ?? "completed") ? .completed : .failed)
        return SubAgentTask(id: id, title: title, detail: (starting ? json["profile"] : json["summary"]) as? String ?? "", status: status,
                            sessionID: json["child_session_id"] as? String, runID: json["child_run_id"] as? String)
    }

    private func waitingIndex(title: String) -> Int? {
        if pending.count == 1 { return 0 }
        let titled = pending.indices.filter { pending[$0].title == title }
        return titled.count == 1 ? titled[0] : nil
    }

    static func stableID(_ text: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
