import Foundation

/// recs1 metadata keys. Every key of a user row that answers a suggestion starts with `prefix`, so the detector never
/// counts such a row as an ask.
enum SuggestionKey {
    static let prefix = "suggestion."
    /// On the bot's suggestion row: the record it asks for.
    static let record = "suggestion.record"
    /// On the user's answer: the record it answers, `yes` / `no` / `other`, and the lead sent to the bot before the text.
    static let answers = "suggestion.answers", answer = "suggestion.answer", lead = "suggestion.lead"
    /// On a user row a suggested-reply chip sent ("1"), and the id of the message the chip was under.
    static let chip = "suggestion.chip", chipRow = "suggestion.chipRow"
    /// On the user's yes once its turn was followed through ("1"), so it happens once.
    static let followed = "suggestion.followed"
}

/// One suggestion SwarmHub had a bot ask, and what came of it. `declined` is for good; `asked` (no answer) and `accepted`
/// (a yes) pause that pattern for 7 days; after a yes the routine that exists then keeps it quiet.
struct BotSuggestionRecord: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case asked, declined, accepted }
    var id = UUID()
    var botID: UUID; var stems: [String]; var example: String; var askedAt: Date; var state: State
    var messageID: UUID; var draft: RoutineDraft
}

/// The suggestion state kept on the Mac (`UserDefaults`, one JSON value).
struct BotSuggestionLedger: Codable, Equatable, Sendable {
    var records: [BotSuggestionRecord] = []
    /// When each suggestion message was posted, any bot (the daily cap); two days are kept.
    var posted: [Date] = []

    /// Old posts and unanswered records older than 60 days go; declines and yeses stay (they are for good).
    mutating func prune(now: Date) {
        posted.removeAll { now.timeIntervalSince($0) > 2 * 86_400 }
        records.removeAll { $0.state == .asked && now.timeIntervalSince($0.askedAt) > 60 * 86_400 }
    }
}

/// The anti-annoyance rules (Konrad, 2026-10-23): off switch, no messages 23:00–08:00 local, at most three a day across
/// all bots, a pattern declined is never asked again, an unanswered one not for 7 days.
enum SuggestionPolicy {
    static let dailyCap = 3, quietStart = 23, quietEnd = 8
    static let unansweredPause: TimeInterval = 7 * 86_400

    enum Refusal: Equatable, Sendable { case off, quietHours, dailyCap, declined, accepted, askedRecently }

    static func isQuiet(_ now: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= quietStart || hour < quietEnd
    }

    static func postedToday(_ ledger: BotSuggestionLedger, now: Date, calendar: Calendar) -> Int {
        ledger.posted.filter { calendar.isDate($0, inSameDayAs: now) }.count
    }

    /// The records of `botID` about the same request as `stems`.
    static func records(_ ledger: BotSuggestionLedger, botID: UUID, stems: Set<String>) -> [BotSuggestionRecord] {
        ledger.records.filter { $0.botID == botID && AskText.similar(Set($0.stems), stems) }
    }

    /// Why nothing may be asked now, or nil when the bot may ask.
    static func refusal(stems: Set<String>, botID: UUID, ledger: BotSuggestionLedger, enabled: Bool, now: Date, calendar: Calendar) -> Refusal? {
        guard enabled else { return .off }
        let earlier = records(ledger, botID: botID, stems: stems)
        if earlier.contains(where: { $0.state == .declined }) { return .declined }
        if earlier.contains(where: { $0.state == .accepted && now.timeIntervalSince($0.askedAt) < unansweredPause }) { return .accepted }
        if earlier.contains(where: { $0.state == .asked && now.timeIntervalSince($0.askedAt) < unansweredPause }) { return .askedRecently }
        if isQuiet(now, calendar: calendar) { return .quietHours }
        if postedToday(ledger, now: now, calendar: calendar) >= dailyCap { return .dailyCap }
        return nil
    }
}

/// How the user answered: a quick reply or anything typed.
enum SuggestionAnswer: String, Sendable {
    case yes, no, other

    static let negative: Set<String> = ["no", "nope", "nah", "never", "nie", "dont", "stop"]
    static let negativePhrases = ["no thanks", "no thank you", "do not", "don t", "not interested", "stop asking", "nie dzieki", "nie trzeba"]
    static let affirmative: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "absolutely", "tak", "jasne", "pewnie", "dobrze"]
    static let affirmativePhrases = ["do it", "please do", "go ahead", "sounds good", "why not", "let s do it"]

    /// The first word decides ("Yes, but not on Fridays" is a yes); otherwise a phrase anywhere ("I don't need it" is a no).
    static func classify(_ text: String) -> SuggestionAnswer {
        let normalized = AskText.normalized(text)
        let words = " " + normalized + " "
        let first = normalized.split(separator: " ").first.map(String.init) ?? ""
        if affirmative.contains(first) { return .yes }
        if negative.contains(first) { return .no }
        if negativePhrases.contains(where: { words.contains(" \($0) ") }) { return .no }
        if affirmativePhrases.contains(where: { words.contains(" \($0) ") }) { return .yes }
        return .other
    }

    /// Words that make an `other` reply about the offer (a time, days, the wording); anything else is a new subject.
    static let scheduleWords: Set<String> = ["time", "times", "hour", "hours", "am", "pm", "morning", "mornings", "evening", "evenings", "afternoon",
                                             "night", "noon", "daily", "day", "days", "weekday", "weekdays", "weekend", "weekends", "week", "weekly",
                                             "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                             "mondays", "tuesdays", "wednesdays", "thursdays", "fridays", "saturdays", "sundays", "every", "instead",
                                             "earlier", "later", "routine", "schedule", "wording", "prompt", "rano", "wieczorem", "godzina", "codziennie"]

    /// The words a day list may hold besides the days ("only Mon and Wed", "Mon to Fri", "not Fri").
    static let dayListWords = CronDays.joiners.union(CronDays.refusers).union(["only", "just", "to", "through", "thru", "till", "until"])

    /// An `other` reply that talks about the offer: it names a time or a schedule word; or the day parser reads days in it
    /// once its short day names are left out (so every form the parser knows counts: "workdays only", "everyday", "daily",
    /// "every day", "only on Tuesdays", "Monday to Friday", "not on weekends"); or it is a day list ("Mon/Wed/Fri", "sat and
    /// sun"). A short day ("sat", "sun", "wed") anywhere else is a word of another subject ("I sat down to work", "the sun
    /// is out today").
    static func isAboutTheOffer(_ text: String) -> Bool {
        let words = AskText.normalized(text).split(separator: " ").map(String.init)
        return words.contains { scheduleWords.contains($0) || $0.first?.isNumber == true } || !OfferChange.times(in: text).isEmpty
            || OfferChange.days(in: words.filter { !CronDays.isShortDay($0) }.joined(separator: " ")) != nil
            || (OfferChange.days(in: text) != nil && words.allSatisfy { CronDays.isDay($0) || dayListWords.contains($0) })
    }
}

/// The words of a suggestion: the bot's question, its quick replies and the lead that goes to the bot with the answer.
enum BotSuggestionCopy {
    static let differentTime = "Different time", noThanks = "No thanks"

    /// "You've asked me for “Summarize my inbox” 3 times this week. Want me to run it every weekday at 8:00?"
    static func question(_ repeated: RepeatedAsk, draft: RoutineDraft, now: Date) -> String {
        let earliest = repeated.asks.map(\.at).min() ?? now
        let span = now.timeIntervalSince(earliest) <= 7 * 86_400 ? "this week" : "in the last two weeks"
        return "You've asked me for “\(quote(repeated.anchor.text))” \(repeated.asks.count) times \(span). Want me to run it \(draft.when)?"
    }

    static func replies(_ draft: RoutineDraft) -> [String] { ["Yes, \(draft.when)", differentTime, noThanks] }

    /// The ask on one line, without closing punctuation, at most 80 characters.
    static func quote(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "?!.,;:")))
        if line.count > 80 { line = String(line.prefix(79)).trimmingCharacters(in: .whitespaces) + "…" }
        return line
    }

    /// Sent before the user's answer (never shown in the bubble), so the bot knows what it is answering and can make the
    /// routine with its own cron tool, kept on the box (`deliver 'local'`, as the app's own routines; Hermes's default
    /// sends a cron's output to a home channel). Nothing is made without a yes. recsfix1: the schedule is the draft's in
    /// the box's zone (`draft.boxSchedule`), and the lead says how the two clocks differ, so the bot converts any other
    /// time the user names and tells them their own.
    static func lead(question: String, draft: RoutineDraft, zones: RoutineZones, app: String = AppConstants.name) -> String {
        let box = draft.boxSchedule ?? zones.boxSchedule(draft.schedule), mine = zones.local.identifier
        let clocks = zones.isSame ? "(cron, \(draft.time) in my time zone \(mine), which your cron runs in too)"
            : "(cron in your time zone \(zones.boxName): that is \(draft.time) in my time zone \(mine))"
        return """
        (\(app) asked this in your chat for you: "\(question)" The routine it offered: name "\(draft.name)", schedule `\(box)` \
        \(clocks), prompt "\(draft.prompt)". If my answer below is yes, create that routine now with your cron tool, with deliver \
        'local', with any change I ask for, without asking me to confirm again.\(difference(zones.shift(draft.schedule), zones: zones)) \
        When you tell me a time, say it in my time zone. If I want another time or wording, settle it with me first, and end each \
        message where you offer a changed routine with one line: Routine: name "…", schedule `<cron in your time zone>`, prompt "…". \
        If I say no, just acknowledge it. Create nothing without my yes. My answer:)
        """
    }

    /// " My clock is 2 h ahead of yours, so a time I name is 2 h earlier in your cron." (nothing when they agree).
    static func difference(_ minutes: Int, zones: RoutineZones) -> String {
        guard minutes != 0, !zones.isSame else { return "" }
        let hours = abs(minutes) / 60, rest = abs(minutes) % 60
        let size = [hours > 0 ? "\(hours) h" : nil, rest > 0 ? "\(rest) min" : nil].compactMap { $0 }.joined(separator: " ")
        let ahead = minutes > 0
        return " My clock is \(size) \(ahead ? "ahead of" : "behind") yours, so a time I name is \(size) \(ahead ? "earlier" : "later") in your cron."
    }
}

extension ChatMessage {
    /// Suggested replies (recs1): short answers shown as chips under a bot message. Any bot message can carry them; a chip
    /// sends its text as the user's reply, and typing anything else works the same. Kept in `metadata` as one JSON array,
    /// so the store format and older builds need nothing new.
    static let suggestedRepliesKey = "replies.suggested"
    var suggestedReplies: [String] {
        get { metadata[Self.suggestedRepliesKey].flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [] }
        set {
            let replies = newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            metadata[Self.suggestedRepliesKey] = replies.isEmpty ? nil : (try? JSONEncoder().encode(replies)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
