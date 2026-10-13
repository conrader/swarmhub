import Foundation

/// Pure group-chat rules: who a message goes to, which Hermes session each bot uses, and the transcript
/// a bot receives as context for its turn.
enum GroupRouting {
    static let userName = "Konrad"
    /// Upper bound for the context sent with one bot's turn.
    static let contextLimit = 8_000

    struct Member: Equatable { var id: UUID; var name: String }

    /// `group-<group id>-<bot id>` (lowercased UUIDs); created through the normal session-create path.
    static func sessionID(group: UUID, bot: UUID) -> String { "group-\(group.uuidString.lowercased())-\(bot.uuidString.lowercased())" }

    /// Members addressed with `@Name` (case-insensitive; names may contain spaces). The `@` must start the
    /// text or follow a non-word character, so `konrad@dmt.zone` is not a mention; the name must end at a
    /// word boundary. Unknown names are ignored. Returns ids in member order.
    static func mentions(in text: String, members: [Member]) -> [UUID] {
        let byLength = members.sorted { $0.name.count > $1.name.count }
        var found: Set<UUID> = []
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            let after = text.index(after: at)
            defer { index = after }
            if at > text.startIndex, isWordLike(text[text.index(before: at)]) { continue }
            let rest = text[after...]
            for member in byLength where !member.name.isEmpty && rest.count >= member.name.count {
                let end = rest.index(rest.startIndex, offsetBy: member.name.count)
                guard rest[rest.startIndex..<end].caseInsensitiveCompare(member.name) == .orderedSame, endsAtBoundary(text, end) else { continue }
                found.insert(member.id); break
            }
        }
        return members.map(\.id).filter(found.contains)
    }

    /// Mentioned members, or every member when nobody (known) is mentioned.
    static func recipients(of text: String, members: [Member]) -> [UUID] {
        let mentioned = mentions(in: text, members: members)
        return mentioned.isEmpty ? members.map(\.id) : mentioned
    }

    /// The `@partial` being typed at the end of the composer text, if any (for the autocomplete popup).
    static func typedMention(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, isWordLike(text[text.index(before: at)]) { return nil }
        let partial = String(text[text.index(after: at)...])
        guard partial.count <= 40, !partial.contains("\n"), !partial.hasPrefix(" ") else { return nil }
        return partial
    }

    static func suggestions(for partial: String, names: [String]) -> [String] {
        names.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial.lowercased()) }.filter { $0.caseInsensitiveCompare(partial) != .orderedSame }
    }

    /// Replaces the trailing `@partial` with `@Name `.
    static func complete(_ text: String, with name: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + name + " "
    }

    /// The group transcript since `bot`'s last reply as author-prefixed lines, capped at `limit` characters
    /// (oldest lines dropped first; an oversized newest line is cut).
    static func context(for bot: Member, groupName: String, members: [Member], messages: [ChatMessage], limit: Int = contextLimit) -> String {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let start = (messages.lastIndex { $0.role == .assistant && $0.authorID == bot.id && !$0.content.isEmpty }).map { $0 + 1 } ?? 0
        let lines: [String] = messages[start...].compactMap { message in
            let text = message.outgoingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !message.isSteer, message.role != .system else { return nil }
            let author = message.role == .user ? userName : message.authorID.flatMap { names[$0] } ?? "Bot"
            return "\(author): \(text)"
        }
        let others = members.filter { $0.id != bot.id }.map(\.name)
        let header = "[Group chat “\(groupName)” with \(([userName] + others).joined(separator: ", ")) and you (\(bot.name)). Messages since your last reply:]"
        let omitted = "[… earlier messages omitted]"
        var kept: [String] = []; var used = header.count + 1
        for line in lines.reversed() {
            let cost = line.count + 1
            if used + cost + omitted.count + 1 > limit {
                if kept.isEmpty { kept.append(String(line.prefix(max(0, limit - used - omitted.count - 2)))) }
                kept.append(omitted); break
            }
            kept.append(line); used += cost
        }
        return ([header] + kept.reversed()).joined(separator: "\n")
    }

    private static func isWordLike(_ character: Character) -> Bool { character.isLetter || character.isNumber || "._-+@".contains(character) }
    private static func endsAtBoundary(_ text: String, _ end: String.Index) -> Bool {
        guard end < text.endIndex else { return true }
        let next = text[end]
        if next.isLetter || next.isNumber || next == "_" || next == "-" || next == "@" { return false }
        if next == "." { let after = text.index(after: end); return after == text.endIndex || !(text[after].isLetter || text[after].isNumber) }
        return true
    }
}
