import Foundation

/// Pure group-chat rules: who a message goes to, which session each bot uses, and the transcript
/// a bot receives as context for its turn.
enum GroupRouting {
    /// The author label of the user's lines when no name is passed (tests); the app passes `AppStore.userName` (P21 D6).
    static let defaultUserName = "Konrad"
    /// Upper bound for the context sent with one bot's turn.
    static let contextLimit = 8_000
    static let contextThrough = "groupContextThrough"

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

    /// Mentioned members, or every member when nobody (known) is mentioned. P38: names two members share are
    /// matched as `Name#id` (`mentionName`).
    static func recipients(of text: String, members: [Member]) -> [UUID] {
        let mentioned = mentions(in: text, members: mentionable(members))
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

    static func herdrContext(for bot: Member, groupName: String, members: [Member], messages: [ChatMessage],
                             current: ChatMessage, limit: Int, userName: String) throws -> String {
        let message = "\(userName): \(current.modelText)"
        try HerdrClient.validateMessage(message, limit: limit)
        let room = limit - HerdrClient.plain(message, bytes: Int.max).utf8.count - 1
        let previous = messages.prefix { $0.id != current.id }
        let earlier = context(for: bot, groupName: groupName, members: members, messages: Array(previous),
                              limit: max(0, room), userName: userName)
        let prefix = HerdrClient.plain(earlier, bytes: max(0, room))
        return prefix.isEmpty ? message : prefix + "\n" + message
    }

    /// Replaces the trailing `@partial` with `@Name `.
    static func complete(_ text: String, with name: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + name + " "
    }

    /// The group transcript since `bot`'s last reply as author-prefixed lines, capped at `limit` characters
    /// (oldest lines dropped first; an oversized newest line is cut). The attachment text of the `current`
    /// message (documents and text files) follows its line whole and does not count towards `limit`; the
    /// backend splits long text into parts and guards the request size as in 1:1 chats.
    static func context(for bot: Member, groupName: String, members: [Member], messages: [ChatMessage], current: UUID? = nil, limit: Int = contextLimit, userName: String = defaultUserName) -> String {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // A choice goes to one recipient. A later queued message (or a reply appended
        // after this bubble) belongs to a different round.
        let transcript: ArraySlice<ChatMessage>
        if let current, let index = messages.firstIndex(where: { $0.id == current }), messages[index].metadata[ChoiceReply.cardKey] != nil {
            transcript = messages[...index]
        } else {
            transcript = messages[...]
        }
        // A continuation is output from the same request. Rows posted by other members
        // while it was running have never been sent to this member. A moved placeholder
        // has no row left at its original position, but still names its trigger.
        var start = transcript.startIndex
        if let last = transcript.lastIndex(where: { $0.authorID == bot.id && $0.role == .assistant && !$0.content.isEmpty }) {
            let reply = transcript[last]
            start = last + 1
            let previous = transcript[...last]
            if let seen = reply.metadata[contextThrough], let index = previous.firstIndex(where: { $0.id.uuidString == seen }) {
                start = index + 1
            } else if let trigger = reply.metadata[TurnKey.forUser], reply.continuedAt != nil || reply.metadata[TurnKey.part] != nil {
                // Earlier builds saved the trigger and parts, but no context boundary.
                let origin = previous.lastIndex { $0.authorID == bot.id && $0.metadata[TurnKey.forUser] == trigger
                    && $0.metadata[TurnKey.part] == "1" && $0.continuedAt == nil }
                if let index = origin ?? previous.firstIndex(where: { $0.id.uuidString == trigger }) { start = index + 1 }
            }
        }
        let lines: [(label: Int, line: String, files: String?)] = transcript[start...].compactMap { message in
            let isCurrent = current != nil && message.id == current
            let files = isCurrent ? AttachmentEncoder.compose(text: "", attachments: message.attachments) : ""
            let text = (isCurrent ? message.modelText : message.outgoingText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !files.isEmpty, !message.isSteer, message.role != .system, !(message.role == .assistant && message.authorID == bot.id) else { return nil }
            let author = message.role == .user ? userName : message.authorID.flatMap { names[$0] } ?? "Bot"
            return (author.count + 1, text.isEmpty ? "\(author):" : "\(author): \(text)", files.isEmpty ? nil : files)
        }
        let others = members.filter { $0.id != bot.id }.map(\.name)
        let header = "[Group chat “\(groupName)” with \(([userName] + others).joined(separator: ", ")) and you (\(bot.name)). Messages since your last reply:]"
        let omitted = "[… earlier messages omitted]"
        var kept: [String] = []; var used = header.count + 1; var full = false; var dropped = false
        for (label, line, files) in lines.reversed() {
            let cost = line.count + 1
            if !full, used + cost + omitted.count + 1 <= limit { kept.append(line + (files.map { "\n\n" + $0 } ?? "")); used += cost; continue }
            // Past the cap only an oversized newest line (cut) and the current message survive; the current
            // message keeps at least its author label so its attachments stay attributed.
            if kept.isEmpty || files != nil {
                if dropped { kept.append(omitted); dropped = false }
                let room = max(files == nil ? 0 : label, limit - used - omitted.count - 2)
                kept.append(String(line.prefix(room)) + (files.map { "\n\n" + $0 } ?? "")); used += min(room, line.count) + 1
                dropped = room < line.count
            } else { dropped = true }
            full = true
        }
        if dropped { kept.append(omitted) }
        return ([header] + kept.reversed()).joined(separator: "\n")
    }

    /// One entry of a context blob: `author` nil is the "[… earlier messages omitted]" marker.
    struct ContextEntry: Equatable { var author: String?; var text: String }
    static let omittedMarker = "[… earlier messages omitted]"

    /// P16: the entries of a blob built by `context`, split at lines that start with a known author's "Name:" (longest
    /// name first); other lines continue the entry above. nil when the text is not a group context.
    static func parseContext(_ blob: String, names: [String], userName: String = defaultUserName) -> [ContextEntry]? {
        var lines = blob.components(separatedBy: "\n")
        guard let header = lines.first, header.hasPrefix("[Group chat “") else { return nil }
        lines.removeFirst()
        let authors = Array(Set(names + [userName, "Bot"])).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var entries: [ContextEntry] = []
        for line in lines {
            if line == omittedMarker { entries.append(.init(author: nil, text: "")); continue }
            if let author = authors.first(where: { line == "\($0):" || line.hasPrefix("\($0): ") }) {
                entries.append(.init(author: author, text: String(line.dropFirst(author.count + 1)).trimmingCharacters(in: .whitespaces)))
            } else if !entries.isEmpty, entries[entries.count - 1].author != nil {
                entries[entries.count - 1].text += "\n" + line
            }
        }
        return entries.map { .init(author: $0.author, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
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
