import Foundation

extension HermesBackend {
    /// A box row: integer `id` (a numeric string is accepted too), `finish_reason` kept; image data URLs in user rows
    /// (the box returns them whole) become a bare `[Image: inline]` line, which `comparable` ignores. `display_kind` is kept.
    /// P43 (`toolCalls`): an assistant row's `tool_calls` names are kept, and a row with only tool calls is kept too (reconcile
    /// draws the steps where they happened).
    static func parseMessage(_ row: [String: Any], toolCalls: Bool = false) -> BackendMessage? {
        let tools = toolCalls && row["role"] as? String == "assistant" ? toolNames(row["tool_calls"]) : []
        guard let role = row["role"] as? String, ["user", "assistant", "system"].contains(role),
              var content = normalizedContent(row["content"]) ?? (tools.isEmpty ? nil : ""), !content.isEmpty || !tools.isEmpty else { return nil }
        if role == "user", content.contains("[Image: data:") {
            content = content.components(separatedBy: "\n").map { $0.hasPrefix("[Image: data:") ? "[Image: inline]" : $0 }.joined(separator: "\n")
        }
        let rawDate = row["created_at"] ?? row["timestamp"]
        let date: Date?
        if let seconds = rawDate as? Double { date = Date(timeIntervalSince1970: seconds) }
        else if let seconds = rawDate as? Int { date = Date(timeIntervalSince1970: Double(seconds)) }
        else if let value = rawDate as? String { date = ISO8601DateFormatter().date(from: value) }
        else { date = nil }
        let rawID = row["id"] ?? row["message_id"]
        let id = (rawID as? Int) ?? (rawID as? String).flatMap { Int($0) }
        var message = BackendMessage(id: id, role: role, content: content, createdAt: date, finishReason: row["finish_reason"] as? String, tools: tools)
        message.displayKind = (row["display_kind"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return message
    }

    /// `tool_calls` as an array (or its JSON string) of `{function: {name}}` or `{name}` entries.
    static func toolNames(_ value: Any?) -> [String] {
        var calls = value as? [[String: Any]]
        if calls == nil, let text = value as? String, let data = text.data(using: .utf8) { calls = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] }
        return (calls ?? []).compactMap { call in
            let name = ((call["function"] as? [String: Any])?["name"] ?? call["name"]) as? String
            return name.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    static func normalizedContent(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if value == nil || value is NSNull { return nil }
        if let object = value as? [String: Any] { return object["text"] as? String }
        guard let parts = value as? [Any] else { return nil }
        let rendered = parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            guard let object = part as? [String: Any] else { return nil }
            if let text = object["text"] as? String { return text }
            let image = object["image_url"]
            if let url = image as? String { return "[Image: \(url)]" }
            if let image = image as? [String: Any], let url = image["url"] as? String { return "[Image: \(url)]" }
            return nil
        }.filter { !$0.isEmpty }
        return rendered.isEmpty ? nil : rendered.joined(separator: "\n")
    }
}
