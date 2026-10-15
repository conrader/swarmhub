import Foundation

/// P46 3: a bot's heartbeat is one Hermes routine (`swarmhub-heartbeat`, `deliver: bot-chat:<profile>`): the box runs it in
/// a fresh cron session and, unless it answered `[SILENT]`, hands its output to the bot's "Bot Chat" session for a full
/// turn. This is what SwarmHub keeps of it: interval, active hours (Mac local time) and the prompt. Pure.
struct HeartbeatPlan: Codable, Equatable, Sendable {
    static let defaultPrompt = "Heartbeat: check what's open for Konrad (messages, routines, goals, files you're watching). If something needs him, say it briefly; otherwise reply exactly [SILENT]."
    static let jobName = "swarmhub-heartbeat"
    /// The title Hermes's `bot-chat:<profile>` delivery looks for (`hermes chat -c "Bot Chat"`).
    static let botChatTitle = "Bot Chat"
    static let intervals: [TimeInterval] = [900, 1_800, 3_600, 7_200, 10_800, 21_600, 86_400]

    var interval: TimeInterval = 3_600
    /// Minutes after midnight, both ends included; an end before the start runs over midnight; nil: all day.
    var windowStart: Int? = 8 * 60; var windowEnd: Int? = 23 * 60
    var prompt: String = defaultPrompt

    static func delivery(_ profile: String) -> String { "bot-chat:\(profile)" }

    /// "hourly 08–23", "every 30 min".
    var label: String {
        var text = ScheduleInterval.label(interval)
        if let windowStart, let windowEnd { text += " \(Self.clock(windowStart))–\(Self.clock(windowEnd))" }
        return text
    }

    func inWindow(minute: Int) -> Bool {
        guard let windowStart, let windowEnd else { return true }
        return windowStart <= windowEnd ? (windowStart...windowEnd).contains(minute) : minute >= windowStart || minute <= windowEnd
    }

    /// The local minutes of the day it runs, `stagger` minutes past the hour (or past the window's first hour).
    func runMinutes(stagger: Int) -> [Int] {
        let step = max(1, Int((interval / 60).rounded()))
        let base = (windowStart ?? 0) / 60 * 60
        if step >= 1_440 {
            // Daily: the first hour of the window (in window order) at the stagger minute.
            let first = (0..<24).map { (base + $0 * 60 + stagger) % 1_440 }.first(where: inWindow)
            return first.map { [$0] } ?? []
        }
        let offset = stagger % step
        let times = stride(from: 0, to: 1_440, by: step).map { (base + offset + $0) % 1_440 }.filter(inWindow)
        return Array(Set(times)).sorted()
    }

    /// Wakes per day; each non-silent one costs two agent turns (the cron run and the chat turn).
    func wakesPerDay(stagger: Int = 0) -> Int { runMinutes(stagger: stagger).count }

    /// The cron expression in the box's time zone (`boxOffset`, `localOffset`: minutes east of UTC). Minutes and hours are
    /// written as lists; a step that does not divide an hour is rounded to the nearest one cron can say.
    func cron(stagger: Int, localOffset: Int, boxOffset: Int) -> String {
        let shift = localOffset - boxOffset
        let times = runMinutes(stagger: stagger).map { (($0 - shift) % 1_440 + 1_440) % 1_440 }
        guard !times.isEmpty else { return "\(stagger % 60) \(((windowStart ?? 0) / 60 - shift / 60 + 24) % 24) * * *" }
        let minutes = Array(Set(times.map { $0 % 60 })).sorted(), hours = Array(Set(times.map { $0 / 60 })).sorted()
        return "\(Self.list(minutes)) \(hours.count == 24 ? "*" : Self.list(hours)) * * *"
    }

    /// "1,3,5", "8-22", "0-6,22-23".
    static func list(_ values: [Int]) -> String {
        var parts: [String] = [], index = 0
        while index < values.count {
            var end = index
            while end + 1 < values.count, values[end + 1] == values[end] + 1 { end += 1 }
            parts.append(end - index >= 2 ? "\(values[index])-\(values[end])" : (index...end).map { String(values[$0]) }.joined(separator: ","))
            index = end + 1
        }
        return parts.joined(separator: ",")
    }

    /// "08" on the hour, else "08:30".
    static func clock(_ minutes: Int) -> String {
        let hour = String(format: "%02d", minutes / 60)
        return minutes % 60 == 0 ? hour : hour + String(format: ":%02d", minutes % 60)
    }

    // MARK: Command

    enum ParseError: Error, Equatable { case noInterval }

    /// `every <interval> [HH:MM–HH:MM] [<prompt>]`; no window means all day, no prompt the default one.
    static func parse(_ arguments: String) -> Result<HeartbeatPlan, ParseError> {
        var words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first?.lowercased() == "every" { words.removeFirst() }
        guard let (seconds, used) = ScheduleInterval.parse(words) else { return .failure(.noInterval) }
        words.removeFirst(used)
        var start: Int?, end: Int?
        if let first = words.first, let window = window(first) { (start, end) = window; words.removeFirst() }
        let prompt = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(HeartbeatPlan(interval: max(seconds, 300), windowStart: start, windowEnd: end, prompt: prompt.isEmpty ? defaultPrompt : prompt))
    }

    /// "08:00–23:00", "8-23", "22:30–06:00".
    static func window(_ text: String) -> (Int, Int)? {
        let halves = text.split(whereSeparator: { $0 == "–" || $0 == "-" || $0 == "—" }).map(String.init)
        guard halves.count == 2, let from = minutes(halves[0]), let to = minutes(halves[1]) else { return nil }
        return (from, to)
    }

    private static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map(String.init)
        guard (1...2).contains(parts.count), let hour = Int(parts[0]), (0...24).contains(hour) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0..<60).contains(minute), hour * 60 + minute <= 24 * 60 else { return nil }
        return min(hour * 60 + minute, 24 * 60 - 1)
    }
}

/// P46 3–4: the minute past the hour each bot's heartbeat runs: spread across the hour by a stable hash of the profile
/// name, and at most `cap` bots of one box in any five-minute slot (the box's advised capacity, P31 E).
enum HeartbeatStagger {
    static let slot = 5

    /// FNV-1a: the same minute on every launch (Swift's `hashValue` is seeded per process).
    static func minute(for profile: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in profile.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % 60)
    }

    /// Profiles in name order keep their hashed minute while its slot has room, else move to the next slot with room.
    static func minutes(for profiles: [String], cap: Int) -> [String: Int] {
        var used: [Int: Int] = [:], result: [String: Int] = [:]
        let slots = 60 / slot, cap = max(1, cap)
        for profile in Set(profiles).sorted() {
            let preferred = minute(for: profile)
            var bucket = preferred / slot, tries = 0
            while used[bucket, default: 0] >= cap, tries < slots { bucket = (bucket + 1) % slots; tries += 1 }
            used[bucket, default: 0] += 1
            result[profile] = bucket * slot + preferred % slot
        }
        return result
    }
}

/// P46: what store.json keeps of heartbeats: the Settings template, each bot's own plan once applied or overridden, the
/// session titled "Bot Chat" per bot (titled once), and a title another session of the profile already holds (ask).
struct HeartbeatSettings: Codable, Equatable, Sendable {
    var template = HeartbeatPlan()
    var plans: [String: HeartbeatPlan] = [:]
    var botChats: [String: String] = [:]
    var conflicts: [String: String] = [:]
    var isEmpty: Bool { self == HeartbeatSettings() }

    func plan(for botID: UUID) -> HeartbeatPlan { plans[botID.uuidString] ?? template }
}

/// P46 2: a row the box appended to a bot's Bot Chat for a `bot-chat:` routine: `[Cronjob "<name>" output — scheduled job,
/// not the user. …]` (`cron/scheduler_delivery.py`).
enum CronDeliveryRow {
    static let prefix = "[Cronjob \""

    /// The routine's name, or nil for any other row.
    static func jobName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let rest = trimmed.dropFirst(prefix.count)
        guard let quote = rest.range(of: "\" output") else { return nil }
        let name = String(rest[..<quote.lowerBound])
        return name.isEmpty ? nil : name
    }

    /// The box's time zone, read from a job time it reported (`…+02:00`, `…Z`): minutes east of UTC.
    static func offsetMinutes(_ stamp: String?) -> Int? {
        guard let stamp = stamp?.trimmingCharacters(in: .whitespaces), stamp.count > 10 else { return nil }
        if stamp.hasSuffix("Z") { return 0 }
        let tail = stamp.suffix(6)
        guard let sign = tail.first, sign == "+" || sign == "-", tail.dropFirst(3).first == ":",
              let hours = Int(tail.dropFirst().prefix(2)), let minutes = Int(tail.suffix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 60 + minutes)
    }
}
