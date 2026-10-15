import Foundation

/// P46 1–2: a bot's sessions as the box lists them (title, size, last activity), and retitling its main chat "Bot Chat"
/// (`PATCH /api/sessions/{id}` `{"title": …}`, the call the 2026-10-15 Jarvis test used).
extension HermesBackend {
    /// `GET api/sessions?[source=<source>&]limit=<limit>&offset=0`, archives left out.
    func sessionListing(source: String?, limit: Int = 100) async throws -> [SessionListing] {
        guard try await transport() == .nativeSessions else { return [] }
        let filter = source.map { "source=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)&" } ?? ""
        let json = try await jsonRequest(path: "api/sessions?\(filter)limit=\(limit)&offset=0", timeout: timeouts.read)
        let rows = (json["data"] as? [[String: Any]]) ?? (json["sessions"] as? [[String: Any]]) ?? []
        return GrokServerArchive.excludingArchives(rows).compactMap(SessionListing.init(row:))
    }

    func setSessionTitle(_ sessionID: String, title: String) async throws {
        _ = try await jsonRequest(path: "api/sessions/\(Self.escapedPath(sessionID))", method: "PATCH", body: ["title": title], timeout: timeouts.control)
    }
}

/// One row of the box's session list.
struct SessionListing: Equatable, Sendable {
    var id: String; var title: String?; var source: String?
    var messageCount: Int?; var lastActive: Double?

    init(id: String, title: String? = nil, source: String? = nil, messageCount: Int? = nil, lastActive: Double? = nil) {
        self.id = id; self.title = title; self.source = source; self.messageCount = messageCount; self.lastActive = lastActive
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let count = (row["message_count"] as? Int) ?? (row["message_count"] as? Double).map { Int($0) }
        let active: Double? = switch row["last_active"] ?? row["updated_at"] {
        case let seconds as Double: seconds
        case let seconds as Int: Double(seconds)
        case let text as String: RoutineTime.date(text)?.timeIntervalSince1970 ?? Double(text)
        default: nil
        }
        self.init(id: id, title: row["title"] as? String, source: row["source"] as? String, messageCount: count, lastActive: active)
    }

    /// What changes when the box appends a row: the count and the last activity.
    var mark: String { "\(messageCount ?? -1)|\(lastActive.map { String(format: "%.3f", $0) } ?? "")" }
}
