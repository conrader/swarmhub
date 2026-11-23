import Foundation

/// What an imported bot's agent is handed so that it can carry on where the conversation stopped in Grok Bot.
/// The agent program keeps its own memory and a new agent starts with none, so the earlier conversation has to be
/// given to every agent the bot starts (`HerdrHandoff`). It goes as two files: `grok-handoff.md`, a summary of the
/// older part followed by the most recent part word for word, and `grok-history-full.md`, the whole transcript with
/// one searchable prefix per message.
/// Everything here is pure: the same lines give the same bytes. Every line goes through today's secret filter again
/// (`Transcript`), whatever filter the file on disk was saved under, and so does a summary before it is written into
/// a file. The summary itself is made elsewhere (`GrokHandoffCache.swift`).
enum GrokHandoff {
    /// The handoff file is at most `fileBytes`: `headBytes` for its opening lines, `summaryBytes` for the summary and
    /// the rest for the most recent part. The app does not know how much an agent program reads at once, so one
    /// careful size serves them all.
    static let fileBytes = 48_000, summaryBytes = 8_000, headBytes = 1_000
    static var recentBytes: Int { fileBytes - summaryBytes - headBytes }
    /// The longest message the recent part keeps whole once the conversation no longer fits; a longer one is cut in
    /// the middle. A message is never cut below `leastMessageBytes`; `headingBytes` is the room its heading may take.
    static let messageBytes = 8_000, leastMessageBytes = 400, headingBytes = 300
    /// Lines a saved summary does not stand for are simply added to the recent part while they are no more than this.
    static let gapBytes = 16_000
    /// The full transcript is at most this (the server takes 8 MiB of files per message); a longer one loses its
    /// oldest lines, and says so. A single line in it is at most `fullLineBytes`.
    static let fullBytes = 6 * 1024 * 1024, fullLineBytes = 1024 * 1024
    /// A message in the note's own excerpt (`HerdrHandoff.note`) is cut to this.
    static let excerptMessageBytes = 600
    static let handoffFile = "grok-handoff.md", fullFile = "grok-history-full.md"

    // MARK: The lines

    /// An archive's lines as they may leave the Mac: each one through today's secret filter.
    struct Transcript: Sendable, Equatable {
        let lines: [ArchivedMessage]
        init(_ saved: [ArchivedMessage]) { lines = saved.map(\.refiltered) }

        /// What was said: the person's and the bots' messages, without hidden prompts, system lines and events.
        var spoken: [ArchivedMessage] { lines.filter(GrokHandoff.isSpoken) }
        /// Changes whenever the archive gains lines: how many it has and the number of its last one.
        var revision: String { "\(lines.count)-\(lines.last?.seq ?? 0)" }
    }

    static func isSpoken(_ line: ArchivedMessage) -> Bool {
        !line.hidden && line.role != "system" && (line.channel == "chat" || line.channel == "agent")
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A message the person wrote in the chat: the recent part starts at one.
    static func isPerson(_ line: ArchivedMessage) -> Bool { line.role == "user" && line.channel == "chat" }

    /// A name on one line, for a heading.
    static func oneLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(80))
    }

    static func speaker(_ line: ArchivedMessage, botName: String) -> String {
        if line.channel == "agent" { return "\(oneLine(line.author ?? "A bot")) → \(oneLine(line.to ?? "a bot"))" }
        switch line.role {
        case "user": return "The person"
        case "system": return "System"
        default: return oneLine(line.author ?? botName)
        }
    }

    /// The start of `text`, at most `bytes` of UTF-8, ending on a whole character.
    static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if used + size > bytes { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// The end of `text`, at most `bytes` of UTF-8, starting on a whole character.
    static func suffix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var used = 0
        var start = text.endIndex
        for index in text.indices.reversed() {
            let size = text[index].utf8.count
            if used + size > bytes { break }
            used += size
            start = index
        }
        return String(text[start...])
    }

    /// `text` whole when it fits `limit` bytes; otherwise its start and its end around one line that says how much is
    /// missing and, unless `whole` is false (the full transcript itself, and what a summary is made from), where the
    /// whole message is.
    static func cut(_ text: String, to limit: Int, seq: Int64, whole: Bool = true, fullFile: String = GrokHandoff.fullFile) -> String {
        guard text.utf8.count > limit else { return text }
        let half = max(limit / 2, 1)
        let head = prefix(text, bytes: half), tail = suffix(text, bytes: half)
        let missing = text.utf8.count - head.utf8.count - tail.utf8.count
        let pointer = whole ? " The whole message is #\(seq) in \(fullFile)" : ""
        return head + "\n[… \(missing) bytes left out here.\(pointer) …]\n" + tail
    }

    /// One message of the recent part: a heading with who, when and its number, then the text.
    static func block(_ line: ArchivedMessage, botName: String, limit: Int, fullFile: String = GrokHandoff.fullFile) -> String {
        var heading = "### \(speaker(line, botName: botName))"
        if let date = line.timestamp { heading += " · \(date.ISO8601Format())" }
        heading += " · #\(line.seq)"
        return heading + "\n" + cut(line.text, to: limit, seq: line.seq, fullFile: fullFile) + "\n\n"
    }

    /// One message of the full transcript: `[#12 2026-01-02T03:04:05Z The person] text`. Hidden prompts, lines
    /// between bots and events are all there, each tagged.
    static func entry(_ line: ArchivedMessage, botName: String) -> String {
        var who = [speaker(line, botName: botName)]
        if line.hidden { who.append("hidden prompt") }
        if line.channel == "agent" { who.append("bot to bot") }
        if line.channel == "event" { who.append("event") }
        let time = line.timestamp.map { " " + $0.ISO8601Format() } ?? ""
        return "[#\(line.seq)\(time) \(who.joined(separator: " · "))] \(line.text)\n"
    }

    // MARK: The layout

    /// How a conversation is laid out for the handoff file.
    struct Plan: Sendable, Equatable {
        /// The older part, oldest first: what a summary stands for. Empty when everything fits word for word.
        var older: [ArchivedMessage]
        /// The most recent part, word for word.
        var recent: [ArchivedMessage]
        /// The longest a message of the recent part may be before it is cut in the middle.
        var messageLimit: Int
        /// The saved summary the plan was made with stands for the whole older part (or there is no older part).
        var covered: Bool
        var needsSummary: Bool { !older.isEmpty && !covered }
    }

    /// Everything word for word while it fits the file. Otherwise the newest messages that fit `recentBytes`,
    /// starting at a message of the person and holding at least the last two exchanges (their messages cut to equal
    /// shares when they are too long), and the rest as the older part.
    /// `summarisedThrough`: the number of the last message a saved summary stands for. Messages after it that would
    /// fall into the older part are added to the recent part while they are few (`gapBytes`), so a small update of the
    /// archive needs no new summary; with more of them the summary no longer covers the older part.
    static func plan(_ transcript: Transcript, botName: String, summarisedThrough: Int64? = nil) -> Plan {
        let spoken = transcript.spoken
        let whole = spoken.map { block($0, botName: botName, limit: Int.max).utf8.count }
        if whole.reduce(0, +) <= fileBytes - headBytes {
            return Plan(older: [], recent: spoken, messageLimit: Int.max, covered: true)
        }
        var limit = messageBytes
        let sizes = spoken.map { block($0, botName: botName, limit: messageBytes).utf8.count }
        // The newest messages that fit, and the earliest message of the person among them.
        var start = spoken.count, total = 0
        var fromPerson: Int? = nil
        for index in spoken.indices.reversed() {
            total += sizes[index]
            if total > recentBytes { break }
            start = index
            if isPerson(spoken[index]) { fromPerson = index }
        }
        var first = fromPerson ?? start
        // The last two exchanges are there even when they are long: each of their messages then gets an equal share.
        let persons = spoken.indices.filter { isPerson(spoken[$0]) }
        if let least = persons.suffix(2).first, least < first {
            let share = recentBytes / (spoken.count - least) - headingBytes
            if share >= leastMessageBytes { first = least; limit = min(limit, share) }
        }
        var covered = false
        if let through = summarisedThrough {
            // The first message the saved summary does not stand for.
            let next = spoken.firstIndex(where: { $0.seq > through }) ?? spoken.count
            if next >= first {
                covered = true
            } else if sizes[next..<first].reduce(0, +) <= gapBytes {
                first = next; covered = true
            }
        }
        return Plan(older: Array(spoken[..<first]), recent: Array(spoken[first...]), messageLimit: limit, covered: covered || first == 0)
    }

    // MARK: The files

    /// The two files, and what the note that carries them says of them.
    struct Rendered: Sendable, Equatable {
        let handoff: Data, full: Data
        let revision: String
        /// The summary as it stands in the handoff file; nil when the file has none.
        let summary: String?
        /// The last exchanges as short blocks, oldest first.
        let lastExchanges: [String]
        let olderCount: Int, recentCount: Int
    }

    /// A summary as it may be stored and sent: through the secret filter, trimmed, at most `summaryBytes`.
    static func cleanSummary(_ text: String) -> String {
        prefix(SecretFilter.redacted(text, replacement: GrokRedactor.marker).trimmingCharacters(in: .whitespacesAndNewlines), bytes: summaryBytes)
    }

    /// `summary` is the saved summary of the older part, with the messages it stands for: the file names that range,
    /// and says so when the older part goes on after it (a summary made before lines were added, used until a new one
    /// is there). Without one the file says that the older part is in the full transcript.
    static func render(_ transcript: Transcript, plan: Plan, summary: GrokHandoffCache?, botName: String, origin: HerdrHandoff.Origin = .imported) -> Rendered {
        let name = oneLine(botName), fullFile = origin.fullFile
        let cleaned: String = summary.map { cleanSummary($0.summary) } ?? ""
        let clean: String? = plan.older.isEmpty || cleaned.isEmpty ? nil : cleaned
        var text = "# Earlier conversation of \(name)\n\n"
        text += origin == .imported ? "This conversation took place in another app before it moved here. " : "This is what the person and \(name) have said in this chat so far. "
        text += "The complete transcript "
        text += "(\(transcript.lines.count) lines) is \(fullFile); each message there starts with [#number time speaker]. "
        text += "Secrets were replaced by \(GrokRedactor.marker).\n\n"
        if let first = plan.older.first, let last = plan.older.last {
            if let clean, let covers = summary {
                text += "## Summary of the older part (\(covers.messages) messages, #\(covers.from) to #\(covers.through))\n\n\(clean)\n\n"
                if covers.from > first.seq || covers.through < last.seq {
                    text += "The older part runs from #\(first.seq) to #\(last.seq). What this summary does not cover is in \(fullFile).\n\n"
                }
            } else {
                text += "## The older part (\(plan.older.count) messages, #\(first.seq) to #\(last.seq))\n\n"
                text += "The older part is not summarised here. It is in \(fullFile): search that file when something from before the recent part matters.\n\n"
            }
        }
        text += "## The most recent part, word for word (\(plan.recent.count) messages)\n\n"
        text += plan.recent.map { block($0, botName: botName, limit: plan.messageLimit, fullFile: fullFile) }.joined()
        let persons = plan.recent.indices.filter { isPerson(plan.recent[$0]) }
        let from = persons.suffix(2).first ?? max(0, plan.recent.count - 4)
        let exchanges: [String] = plan.recent[from...].suffix(8).map { block($0, botName: botName, limit: excerptMessageBytes, fullFile: fullFile) }
        return Rendered(handoff: Data(text.utf8), full: full(transcript, botName: botName), revision: transcript.revision,
                        summary: clean, lastExchanges: exchanges, olderCount: plan.older.count, recentCount: plan.recent.count)
    }

    /// The whole transcript, oldest first, one `entry` per line of the archive.
    static func full(_ transcript: Transcript, botName: String) -> Data {
        var kept: [String] = []
        var used = 0
        for line in transcript.lines.reversed() {
            // One line that would fill the file by itself is cut in the middle, so that it does not hide every line before it.
            var shown = line
            shown.text = cut(line.text, to: fullLineBytes, seq: line.seq, whole: false)
            let text = entry(shown, botName: botName)
            if used + text.utf8.count > fullBytes { break }
            used += text.utf8.count
            kept.append(text)
        }
        let dropped = transcript.lines.count - kept.count
        var head = "# Complete earlier conversation of \(oneLine(botName))\n\n"
        head += "Every message, oldest first. Each starts with [#number time speaker], so a search for a word, a name or \"[#120 \" finds it. "
        head += "Secrets were replaced by \(GrokRedactor.marker).\n"
        if dropped > 0 { head += "The oldest \(dropped) lines did not fit into this file and are left out.\n" }
        return Data((head + "\n" + kept.reversed().joined()).utf8)
    }

    // MARK: The marker

    /// How every marker of this conversation starts. The note a handoff travels in begins with the marker, and a
    /// saved task that has it shows that the agent session was given the conversation (`HerdrClient.handoffState`).
    static func lead(for archiveID: UUID, origin: HerdrHandoff.Origin = .imported) -> String { "[SwarmHub \(origin == .ownChat ? "chat handoff" : "handoff") \(archiveID.uuidString.lowercased().prefix(8)) " }
    /// The marker of one revision of the archive. Only `lead` is looked for today; the revision is there for telling
    /// a running agent what was added since it read an older one.
    static func marker(for archiveID: UUID, revision: String, origin: HerdrHandoff.Origin = .imported) -> String { lead(for: archiveID, origin: origin) + "r\(revision)]" }

    /// The rendered files as the backend carries them to the agent.
    static func package(_ rendered: Rendered, archiveID: UUID, origin: HerdrHandoff.Origin = .imported) -> HerdrHandoff {
        let files: [HerdrClient.TaskFile] = [
            HerdrClient.TaskFile(name: origin.handoffFile, mime: "text/markdown", data: rendered.handoff),
            HerdrClient.TaskFile(name: origin.fullFile, mime: "text/markdown", data: rendered.full),
        ]
        let prefix = lead(for: archiveID, origin: origin)
        return HerdrHandoff(lead: prefix, marker: marker(for: archiveID, revision: rendered.revision, origin: origin), files: files,
                            summary: rendered.summary, recent: rendered.lastExchanges,
                            olderMessages: rendered.olderCount, recentMessages: rendered.recentCount, origin: origin)
    }
}
