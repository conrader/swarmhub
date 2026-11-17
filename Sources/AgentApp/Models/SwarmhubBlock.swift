import Foundation

/// A ```swarmhub fence in a reply is how a bot's agent asks the app for something: the main bot for a new bot
/// (`HerdrBotRequest`), any other bot for the main bot's help (`HerdrBotRelay`). The chat does not draw the fence:
/// the reply shows without it, and each fence reads as one line that unfolds to the block (`FoldedBlockLine`).
enum SwarmhubBlock {
    /// The reply as the chat shows it: every ```swarmhub fence removed (the stored message keeps it).
    static func visibleText(_ text: String) -> String {
        let found = fences(in: text)
        guard !found.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        for fence in found.reversed() { lines.removeSubrange(fence.lines) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ```swarmhub fences: line range (an unclosed fence runs to the end, as while streaming) and body.
    static func fences(in text: String) -> [(lines: Range<Int>, body: String)] {
        let lines = text.components(separatedBy: "\n"); var result: [(Range<Int>, String)] = []; var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix { $0 == "`" }.count
            guard ticks >= 3, trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased() == "swarmhub" else { index += 1; continue }
            var end = index + 1
            while end < lines.count {
                let line = lines[end].trimmingCharacters(in: .whitespaces)
                if line.count >= ticks, line.allSatisfy({ $0 == "`" }) { break }
                end += 1
            }
            result.append((index..<min(end + 1, lines.count), lines[(index + 1)..<min(end, lines.count)].joined(separator: "\n")))
            index = end + 1
        }
        return result
    }
}

/// A ```swarmhub fence as one plain line made from what it asks for, e.g. "Suggested a new bot: Research". The raw
/// block is never drawn. A block this build does not know, or cannot read, gets no line: nothing comes of it.
enum SwarmhubSummary {
    struct Line: Equatable {
        var summary: String; var block: String
        /// The symbol that goes with what the block asked for.
        var symbol: String {
            if summary.hasPrefix("Wrote to") { return "paperplane" }
            if summary.hasPrefix("Noted") { return "person.text.rectangle" }
            return summary.hasPrefix("Said no") ? "xmark.circle" : "person.crop.circle.badge.plus"
        }
    }

    /// One line per fence, in order (an unclosed fence, as while streaming, too).
    static func lines(in text: String) -> [Line] {
        guard text.contains("`") else { return [] }
        return SwarmhubBlock.fences(in: text).map { Line(summary: summary(body: $0.body), block: $0.body) }.filter { !$0.summary.isEmpty }
    }

    static func summary(body: String) -> String {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return "" }
        let objects = (json as? [String: Any]).map { [$0] } ?? (json as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let parts = objects.map(line).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        let shown = parts.prefix(2).joined(separator: " · ")
        return parts.count > 2 ? shown + " · \(parts.count - 2) more" : shown
    }

    private static func line(_ object: [String: Any]) -> String {
        let op = object["op"] as? String ?? "", name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "a bot"
        switch op {
        case "create_bot": return "Suggested a new bot: \(name)"
        case "request_bot": return "Asked the main bot for a new bot: \(name)"
        case "decline_bot": return "Said no to a new bot: \(name)"
        case "message_bot": return "Wrote to " + ((object["to"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "another bot")
        case "about_you": return "Noted something about you"
        default: return ""
        }
    }

    /// The block as indented JSON when it is JSON, else as written; at most 4,000 characters.
    static func pretty(_ block: String) -> String {
        var text = block
        if let data = block.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data),
           let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { text = String(decoding: out, as: UTF8.self) }
        return text.count > 4_000 ? String(text.prefix(4_000)) + "…" : text
    }
}
