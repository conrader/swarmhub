import Foundation

/// P42: the reads behind a live work card: a session's rows with their tool calls (what each ran on), and a bot's
/// sessions of one source (`oneshot`, `cron`) to find the one a step or a routine run started. GET only.
extension HermesBackend {
    /// The newest `window` rows of a session, oldest first, each assistant row with its tool calls and their previews.
    func workRows(sessionID: String, window: Int = 200) async throws -> [BackendMessage] {
        guard try await transport() == .nativeSessions else { return [] }
        let json = try await jsonRequest(path: "api/sessions/\(Self.escapedPath(sessionID))/messages?order=latest&limit=\(window)&offset=0&inline_images=false",
                                         timeout: timeouts.read)
        guard let rows = json["data"] as? [[String: Any]] else { throw BackendError.unavailable("Hermes returned an invalid messages page.") }
        return rows.compactMap { Self.workRow($0, key: apiKey) }
    }

    /// One row as `parseMessage(_:toolCalls:)` reads it, plus each tool call's preview.
    static func workRow(_ row: [String: Any], key: String = "") -> BackendMessage? {
        guard var message = parseMessage(row, toolCalls: true) else { return nil }
        if !message.tools.isEmpty { message.toolPreviews = toolPreviews(row["tool_calls"], key: key) }
        return message
    }

    /// Each `tool_calls` entry's arguments as one shown line: its command, path, URL, query or name, else its first text value.
    static func toolPreviews(_ value: Any?, key: String = "") -> [String?] {
        var calls = value as? [[String: Any]]
        if calls == nil, let text = value as? String, let data = text.data(using: .utf8) { calls = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] }
        return (calls ?? []).compactMap { call -> String?? in
            let function = call["function"] as? [String: Any]
            guard let name = (function?["name"] ?? call["name"]) as? String, !name.isEmpty else { return nil }
            var args = (function?["arguments"] ?? call["arguments"] ?? call["args"]) as? [String: Any]
            if args == nil, let text = (function?["arguments"] ?? call["arguments"]) as? String, let data = text.data(using: .utf8) {
                args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            guard let args else { return .some(nil) }
            let line = ["command", "cmd", "path", "file_path", "url", "query", "name", "skill"].lazy.compactMap { args[$0] as? String }.first
                ?? args.keys.sorted().lazy.compactMap { args[$0] as? String }.first
            return .some(ToolEvent.preview(line, key: key))
        }
    }

    /// `GET api/sessions?source=<source>`: id, title, source and start of each session, newest first as listed.
    func sessionRows(source: String, limit: Int = 50) async throws -> [BotSessionRow] {
        guard try await transport() == .nativeSessions else { return [] }
        let escaped = source.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source
        let json = try await jsonRequest(path: "api/sessions?source=\(escaped)&limit=\(limit)&offset=0", timeout: timeouts.read)
        let rows = (json["data"] as? [[String: Any]]) ?? (json["sessions"] as? [[String: Any]]) ?? []
        return rows.compactMap(BotSessionRow.init(row:))
    }
}

/// P42: a session as a list shows it, for finding the one a oneshot command or a routine run started.
struct BotSessionRow: Equatable, Sendable {
    var id: String; var title: String?; var source: String?; var startedAt: Date?

    init(id: String, title: String? = nil, source: String? = nil, startedAt: Date? = nil) {
        self.id = id; self.title = title; self.source = source; self.startedAt = startedAt
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let raw = ["started_at", "created_at", "last_active", "updated_at"].lazy.compactMap { row[$0] }.first
        let date: Date? = switch raw {
        case let seconds as Double: Date(timeIntervalSince1970: seconds)
        case let seconds as Int: Date(timeIntervalSince1970: Double(seconds))
        case let value as String: ISO8601DateFormatter().date(from: value) ?? Double(value).map(Date.init(timeIntervalSince1970:))
        default: nil
        }
        self.init(id: id, title: row["title"] as? String, source: row["source"] as? String, startedAt: date)
    }
}
