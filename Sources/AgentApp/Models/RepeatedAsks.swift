import Foundation

/// recs1: how two asks are compared. Local and deterministic (no model, no network): text is normalised, filler words
/// are dropped and each remaining word is cut to a five-character stem, so "summarize", "summarise" and "summary" meet.
enum AskText {
    /// Words that carry no request on their own (English and Polish).
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "as", "into",
        "is", "are", "was", "be", "it", "its", "this", "that", "these", "those", "there", "here", "so", "up", "out", "all",
        "i", "me", "my", "mine", "you", "your", "we", "our", "us", "can", "could", "would", "will", "should", "may", "might",
        "please", "pls", "plz", "hey", "hi", "hello", "ok", "okay", "thanks", "thank", "just", "some", "any", "what", "whats",
        "give", "get", "show", "tell", "let", "know", "do", "does", "did", "again", "now", "also", "more", "next", "continue",
        "go", "yes", "no", "stop", "retry", "why", "how", "done",
        "w", "z", "na", "o", "mi", "mnie", "moje", "moj", "moja", "prosze", "daj", "pokaz", "czy", "jak", "co",
        "jest", "sie", "ze", "dla", "od", "po", "tak", "nie", "jeszcze", "teraz", "dzieki"
    ]

    /// Lower case, accents folded, everything but letters and digits as spaces, whitespace collapsed.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let spaced = String(String.UnicodeScalarView(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? $0 : " " }))
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// The stems of the words that carry the request.
    static func stems(_ text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init)
            .filter { !stopwords.contains($0) && ($0.count > 1 || $0.first?.isNumber == true) }
            .map { String($0.prefix(5)) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// The same request: at least two shared stems and a stem Jaccard of at least 0.6.
    static let threshold = 0.6
    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool { a.intersection(b).count >= 2 && jaccard(a, b) >= threshold }

    /// A routine (its name and prompt) already covers the ask: similar, or holding at least 75% of the ask's stems
    /// (a routine prompt is usually longer than the ask).
    static func covered(_ ask: Set<String>, by routine: Set<String>) -> Bool {
        let shared = ask.intersection(routine).count
        return similar(ask, routine) || (shared >= 2 && Double(shared) / Double(max(ask.count, 1)) >= 0.75)
    }
}

/// One ask: a user row the user typed in a bot's main chat.
struct Ask: Equatable, Sendable {
    let id: UUID; let text: String; let at: Date; let stems: Set<String>
}

/// The asks that repeat the newest one.
struct RepeatedAsk: Equatable, Sendable {
    let anchor: Ask; let asks: [Ask]; let days: Int
}

/// recs1 detector: similar asks to the same bot on at least three distinct local days within 14 days.
enum RepeatedAskDetector {
    static let window: TimeInterval = 14 * 86_400
    static let minimumDays = 3
    /// Longer rows are pasted material, not a request someone repeats.
    static let maximumLength = 280

    /// A row counts as an ask when the user typed it as a normal message: not a steer, correction, slash command, a row
    /// SwarmHub sent for an automation (goal, loop, heartbeat, orientation), a box out-of-band row, an answer to a
    /// suggestion or a row with attachments.
    @MainActor static func isAsk(_ message: ChatMessage) -> Bool {
        guard message.role == .user, message.presentation == .text, message.attachments.isEmpty else { return false }
        let excluded: Set<String> = [SteerKey.steer, SteerKey.correction, SteerKey.outOfBand, SlashKey.line]
        if message.metadata.keys.contains(where: { $0.hasPrefix("automation.") || $0.hasPrefix(SuggestionKey.prefix) || excluded.contains($0) }) { return false }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= maximumLength && !text.hasPrefix("/")
    }

    @MainActor static func asks(in messages: [ChatMessage]) -> [Ask] {
        messages.filter(isAsk).map { Ask(id: $0.id, text: $0.content.trimmingCharacters(in: .whitespacesAndNewlines), at: $0.createdAt, stems: AskText.stems($0.content)) }
    }

    /// The repeat the newest user row belongs to, or nil: that row must be an ask with at least two stems, and the asks
    /// similar to it in the 14 days before `now` must fall on at least three distinct days of `calendar`.
    @MainActor static func detect(_ messages: [ChatMessage], now: Date, calendar: Calendar) -> RepeatedAsk? {
        guard let newest = messages.last(where: { $0.role == .user }), isAsk(newest) else { return nil }
        return detect(asks(in: messages), anchorID: newest.id, now: now, calendar: calendar)
    }

    static func detect(_ asks: [Ask], anchorID: UUID, now: Date, calendar: Calendar) -> RepeatedAsk? {
        guard let anchor = asks.first(where: { $0.id == anchorID }), anchor.stems.count >= 2 else { return nil }
        let same = asks.filter { now.timeIntervalSince($0.at) <= window && $0.at <= now && AskText.similar($0.stems, anchor.stems) }
        let days = Set(same.map { calendar.startOfDay(for: $0.at) }).count
        return days >= minimumDays ? RepeatedAsk(anchor: anchor, asks: same, days: days) : nil
    }
}

/// The routine a suggestion offers: the newest wording as the prompt, weekdays when every ask fell Monday to Friday
/// (else every day), on the hour of the asks' median time of day. Cron text in the Mac's time, as the routine editor
/// writes it.
struct RoutineDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var botID: UUID; var name: String; var schedule: String; var prompt: String
    var weekdaysOnly: Bool; var hour: Int

    static func make(for repeated: RepeatedAsk, botID: UUID, calendar: Calendar) -> RoutineDraft {
        let weekdaysOnly = repeated.asks.allSatisfy { (2...6).contains(calendar.component(.weekday, from: $0.at)) }
        let minutes = repeated.asks.map { calendar.component(.hour, from: $0.at) * 60 + calendar.component(.minute, from: $0.at) }.sorted()
        let hour = minutes.isEmpty ? 9 : minutes[minutes.count / 2] / 60
        return RoutineDraft(botID: botID, name: routineName(repeated.anchor.text), schedule: "0 \(hour) * * \(weekdaysOnly ? "1-5" : "*")",
                            prompt: repeated.anchor.text, weekdaysOnly: weekdaysOnly, hour: hour)
    }

    /// "every weekday at 8:00" / "every day at 18:00".
    var when: String { "\(weekdaysOnly ? "every weekday" : "every day") at \(hour):00" }

    /// The ask's first line without its closing punctuation, first letter capitalised, at most 60 characters.
    static func routineName(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        var name = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "?!.,;:")))
        if name.count > 60 { name = String(name.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
