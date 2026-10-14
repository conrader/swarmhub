import Foundation

/// P34 D5/D6: a bot's bot-msg threads (`swarmhub-from-<sender>` sessions, titled "From <sender>") from one session-list
/// request, and a thread's messages read with that bot's own key.
extension HermesBackend {
    func botThreadRows() async throws -> [BotThreadRow] {
        guard try await transport() == .nativeSessions else { return [] }
        let json = try await jsonRequest(path: "api/sessions?source=api_server&limit=100&offset=0")
        let rows = (json["data"] as? [[String: Any]]) ?? (json["sessions"] as? [[String: Any]]) ?? []
        return rows.compactMap(Self.botThreadRow)
    }

    /// A session row that is a bot-msg thread; its mark is whatever changes when a message lands (count, last activity).
    static func botThreadRow(_ row: [String: Any]) -> BotThreadRow? {
        guard let id = row["id"] as? String, id.hasPrefix(BotThreadKey.sessionPrefix),
              let sender = BotThreadKey.sender(sessionID: id, title: row["title"] as? String), !sender.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            switch row[key] { case let value as String: value; case let value as Int: String(value); case let value as Double: String(value); default: nil }
        }
        let updated = ["last_active", "updated_at", "ended_at", "started_at", "created_at"].lazy.compactMap { row[$0] }.first
        let date: Date? = switch updated {
        case let seconds as Double: Date(timeIntervalSince1970: seconds)
        case let seconds as Int: Date(timeIntervalSince1970: Double(seconds))
        case let value as String: ISO8601DateFormatter().date(from: value) ?? Double(value).map(Date.init(timeIntervalSince1970:))
        default: nil
        }
        let mark = [text("message_count"), text("last_active") ?? text("updated_at"), text("preview")].map { $0 ?? "" }.joined(separator: "|")
        return BotThreadRow(sessionID: id, sender: sender, mark: mark, updatedAt: date, preview: row["preview"] as? String)
    }
}
