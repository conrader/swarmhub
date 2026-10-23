import Foundation

/// The time and days a reply about the offer asks for ("Make it 7:30 instead", "from 9:00 to 7:30", "Mon/Wed/Fri",
/// "weekends only, but not before 10am"), so the routine the conversation settled on is the one the editor opens with.
/// A time or days the text turns down ("from 9:00", "instead of 9", "not on weekends") are not taken.
enum OfferChange {
    private static let clock = try! NSRegularExpression(pattern: #"\b([01]?\d|2[0-3])[:.]([0-5]\d)(?:\s*(am|pm))?\b"#)
    private static let meridiem = try! NSRegularExpression(pattern: #"\b(1[0-2]|0?[1-9])\s*(am|pm)\b"#)
    /// A bare hour only after a word that makes it one ("at 18", "to 7", "not before 10", Polish "o 7" / "na 7").
    private static let bareHour = try! NSRegularExpression(
        pattern: #"\b(?:at|o|to|from|of|than|not|before|after|by|around|until|till|na|z|zamiast)\s+([01]?\d|2[0-3])\b(?![:.]\d)"#)

    /// Words right before a time that turn it down: "from 9 to 7:30", "instead of 9", "rather than 9", "not (at) 9".
    private static let refusing: Set<String> = ["from", "not", "except", "z", "zamiast", "nie"]
    private static let refusingPairs: Set<String> = ["instead of", "rather than", "other than", "no longer", "but not"]

    /// The times named in `text` that it does not turn down, in order.
    static func times(in text: String) -> [(hour: Int, minute: Int)] {
        let lower = text.lowercased(), range = NSRange(lower.startIndex..., in: lower)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? { Range(match.range(at: index), in: lower).map { String(lower[$0]) } }
        func hour24(_ hour: Int, _ suffix: String?) -> Int { suffix == "pm" ? hour % 12 + 12 : suffix == "am" ? hour % 12 : hour }
        var found: [(at: NSRange, hour: Int, minute: Int)] = []
        func add(_ at: NSRange, _ hour: Int, _ minute: Int) {
            if !found.contains(where: { NSIntersectionRange($0.at, at).length > 0 }) { found.append((at, hour, minute)) }
        }
        for match in clock.matches(in: lower, range: range) {
            guard let hour = group(match, 1).flatMap({ Int($0) }), let minute = group(match, 2).flatMap({ Int($0) }) else { continue }
            let suffix = group(match, 3)
            if suffix == nil || hour <= 12 { add(match.range, hour24(hour, suffix), minute) }
        }
        for match in meridiem.matches(in: lower, range: range) {
            if let hour = group(match, 1).flatMap({ Int($0) }) { add(match.range, hour24(hour, group(match, 2)), 0) }
        }
        for match in bareHour.matches(in: lower, range: range) {
            if let hour = group(match, 1).flatMap({ Int($0) }) { add(match.range(at: 1), hour, 0) }
        }
        let words = Set(AskText.normalized(text).split(separator: " ").map(String.init))
        if found.isEmpty, words.contains("noon") || words.contains("midday") { return [(12, 0)] }
        return found.sorted { $0.at.location < $1.at.location }.filter { !isRefused(lower, before: $0.at) }.map { (hour: $0.hour, minute: $0.minute) }
    }

    /// The time `text` asks for: the last one it names and does not turn down ("from 9:00 to 7:30" → 7:30).
    static func time(in text: String) -> (hour: Int, minute: Int)? { times(in: text).last }

    /// "from", "instead of", "not (at)" … just before `range`; a filler "at" / "o" in between is skipped.
    private static func isRefused(_ text: String, before range: NSRange) -> Bool {
        guard let end = Range(NSRange(location: 0, length: range.location), in: text) else { return false }
        var words = AskText.normalized(String(text[end])).split(separator: " ").map(String.init)
        if let last = words.last, ["at", "o", "around", "about"].contains(last) { words.removeLast() }
        guard let last = words.last else { return false }
        return refusing.contains(last) || (words.count >= 2 && refusingPairs.contains(words.suffix(2).joined(separator: " ")))
    }

    /// The cron day-of-week field `text` asks for, starting from `current` (the routine's field): named days and groups
    /// ("Mon/Wed/Fri", "Monday to Friday", "weekdays", "weekends", "every day"), less the days it turns down ("every day
    /// except Friday"; "not on weekends" takes them from `current`). Nil when it names no days or leaves none.
    static func days(in text: String, current: String = "*") -> String? {
        let dashed = text.lowercased().replacingOccurrences(of: #"([a-z])\s*[-–—]\s*([a-z])"#, with: "$1 to $2", options: .regularExpression)
        let words = AskText.normalized(dashed).split(separator: " ").map(String.init)
        var wanted = Set<Int>(), refused = Set<Int>(), refusing = false, index = 0
        while index < words.count {
            let word = words[index]
            if CronDays.refusers.contains(word) { refusing = true; index += 1; continue }
            guard let named = CronDays.group(words, at: index) else {
                if !CronDays.joiners.contains(word) { refusing = false }
                index += 1; continue
            }
            if refusing { refused.formUnion(named.days) } else { wanted.formUnion(named.days) }
            index += named.length
        }
        guard !wanted.isEmpty || !refused.isEmpty else { return nil }
        let days = (wanted.isEmpty ? CronDays.parse(current) ?? CronDays.all : wanted).subtracting(refused)
        return days.isEmpty ? nil : CronDays.field(days)
    }

    /// The routine a bot's message spells out in the line the lead asks for when it offers a change:
    /// `Routine: name "…", schedule `<cron>`, prompt "…"`. Each part that is missing or not a valid daily cron is nil.
    static func routine(in text: String) -> (name: String?, schedule: String?, prompt: String?)? {
        let marks = CharacterSet(charactersIn: "*_->#`").union(.whitespaces)
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.lowercased().trimmingCharacters(in: marks).hasPrefix("routine:") }) else { return nil }
        let plain = String(line).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
                  let range = Range(match.range(at: 1), in: plain) else { return nil }
            let value = plain[range].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let schedule = capture(#"schedule\s*`([^`]+)`"#).flatMap { CronDays.isDailyTime($0) ? $0.split(separator: " ").joined(separator: " ") : nil }
        let found = (name: capture(#"name\s*"([^"]+)""#), schedule: schedule, prompt: capture(#"prompt\s*"(.+)""#))
        return found.name == nil && found.schedule == nil && found.prompt == nil ? nil : found
    }
}

/// The day-of-week field of a cron schedule: 0 = Sunday … 6 = Saturday.
enum CronDays {
    static let all = Set(0...6), weekdays = Set(1...5), weekend: Set<Int> = [0, 6]
    private static let numbers: [String: Int] = [
        "sun": 0, "sunday": 0, "sundays": 0, "mon": 1, "monday": 1, "mondays": 1, "tue": 2, "tues": 2, "tuesday": 2, "tuesdays": 2,
        "wed": 3, "weds": 3, "wednesday": 3, "wednesdays": 3, "thu": 4, "thur": 4, "thurs": 4, "thursday": 4, "thursdays": 4,
        "fri": 5, "friday": 5, "fridays": 5, "sat": 6, "saturday": 6, "saturdays": 6
    ]
    /// Words that turn down the days after them, and the words that may sit between those days ("except Friday and Sunday").
    static let refusers: Set<String> = ["not", "no", "except", "excluding", "without", "skip", "never", "nor", "bez", "oprocz"]
    static let joiners: Set<String> = ["and", "or", "on", "the", "a", "s", "nor", "also", "any"]

    /// A day's name or short name ("monday", "mondays", "mon", "thurs").
    static func isDay(_ word: String) -> Bool { numbers[word] != nil }
    private static let rangeWords: Set<String> = ["to", "through", "thru", "till", "until"]

    /// The days the words at `index` name, and how many words that took.
    static func group(_ words: [String], at index: Int) -> (days: Set<Int>, length: Int)? {
        let word = words[index], next = index + 1 < words.count ? words[index + 1] : ""
        if let first = numbers[word] {
            if rangeWords.contains(next), index + 2 < words.count, let last = numbers[words[index + 2]] {
                var days: Set<Int> = [first], day = first
                while day != last { day = (day + 1) % 7; days.insert(day) }
                return (days, 3)
            }
            return ([first], 1)
        }
        switch (word, next) {
        case ("weekday", _), ("weekdays", _), ("workday", _), ("workdays", _): return (weekdays, 1)
        case ("work", "day"), ("work", "days"), ("working", "day"), ("working", "days"): return (weekdays, 2)
        case ("weekend", _), ("weekends", _): return (weekend, 1)
        case ("daily", _), ("everyday", _), ("codziennie", _): return (all, 1)
        case ("every", "day"), ("each", "day"), ("all", "week"): return (all, 2)
        default: return nil
        }
    }

    /// The days a cron field names ("*", "1-5", "0,6", "mon-fri", "1,3,5"; 7 is Sunday), or nil when it is not one.
    static func parse(_ field: String) -> Set<Int>? {
        let text = field.lowercased()
        if text == "*" || text == "?" { return all }
        var days = Set<Int>()
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-").map { value -> Int? in Int(value).flatMap { (0...7).contains($0) ? $0 % 7 : nil } ?? numbers[String(value)] }
            guard (1...2).contains(ends.count), let first = ends[0], let last = ends[ends.count - 1] else { return nil }
            var day = first; days.insert(day)
            while day != last { day = (day + 1) % 7; days.insert(day) }
        }
        return days.isEmpty ? nil : days
    }

    /// The field for `days`: "*", runs of three or more as ranges ("1-5", "0-4,6"), the rest listed ("0,6", "1,3,5").
    static func field(_ days: Set<Int>) -> String {
        if days == all { return "*" }
        let sorted = days.sorted()
        var parts: [String] = [], start = 0
        while start < sorted.count {
            var end = start
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            if end - start >= 2 { parts.append("\(sorted[start])-\(sorted[end])") } else { parts += sorted[start...end].map { String($0) } }
            start = end + 1
        }
        return parts.joined(separator: ",")
    }

    /// "every weekday" / "every weekend day" / "every day" / "every Monday, Wednesday and Friday".
    static func phrase(_ field: String) -> String {
        guard let days = parse(field) else { return "on days \(field)" }
        if days == all { return "every day" }
        if days == weekdays { return "every weekday" }
        if days == weekend { return "every weekend day" }
        let named = days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { RoutineScheduleDraft.weekdayNames[$0] }
        return "every " + (named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1])
    }

    /// A five-field cron schedule that runs once at a fixed minute and hour on some days of every month ("30 7 * * 1-5").
    static func isDailyTime(_ schedule: String) -> Bool {
        let fields = schedule.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]) else { return false }
        return (0...59).contains(minute) && (0...23).contains(hour) && fields[2] == "*" && fields[3] == "*" && parse(fields[4]) != nil
    }

    /// Two cron schedules that fire at the same times: the same fields, with "00" = "0" and the days compared as days
    /// ("1-5" = "mon-fri", "0,6" = "6,7").
    static func same(_ a: String, _ b: String) -> Bool {
        let left = a.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }, right = b.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard left.count == 5, right.count == 5 else { return left == right }
        for index in 0..<4 where left[index] != right[index] {
            guard let x = Int(left[index]), let y = Int(right[index]), x == y else { return false }
        }
        guard let x = parse(left[4]), let y = parse(right[4]) else { return left[4] == right[4] }
        return x == y
    }
}

extension RoutineDraft {
    /// This routine with the time and days `text` asks for; unchanged when it names neither.
    func adjusted(by text: String) -> RoutineDraft {
        changed(time: OfferChange.time(in: text), days: OfferChange.days(in: text, current: days))
    }

    /// This routine with what the bot's latest reply in the conversation about it offered: the `Routine:` line the lead asks
    /// for (name, schedule and prompt); without it, only a time and days the reply names without doubt (one time).
    func adjusted(byBot text: String) -> RoutineDraft {
        if let line = OfferChange.routine(in: text) {
            var draft = self
            if let name = line.name { draft.name = name }
            if let prompt = line.prompt { draft.prompt = prompt }
            if let schedule = line.schedule, let hour = Int(schedule.split(separator: " ")[1]) {
                draft.schedule = schedule; draft.hour = hour; draft.weekdaysOnly = draft.days == "1-5"
            }
            return draft
        }
        let times = OfferChange.times(in: text)
        let time = Set(times.map { $0.hour * 60 + $0.minute }).count == 1 ? times.first : nil
        return changed(time: time, days: OfferChange.days(in: text, current: days))
    }

    private func changed(time: (hour: Int, minute: Int)?, days: String?) -> RoutineDraft {
        guard time != nil || days != nil else { return self }
        var draft = self
        draft.hour = time?.hour ?? hour
        let minute = time?.minute ?? self.minute, day = days ?? self.days
        draft.weekdaysOnly = day == "1-5"
        draft.schedule = "\(minute) \(draft.hour) * * \(day)"
        return draft
    }
}
