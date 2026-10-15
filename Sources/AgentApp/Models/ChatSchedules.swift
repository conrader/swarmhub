import Foundation

/// P45 3: `/loop [every] <interval> <prompt> [--times N] [--until <condition>]` — the prompt again on that interval while
/// SwarmHub runs (at least 1 min apart).
struct LoopRun: Codable, Equatable, Sendable {
    var prompt: String; var interval: TimeInterval
    /// Runs still allowed (nil: until stopped) and the condition the bot reports as met with a loop block.
    var timesLeft: Int?; var until: String?
    var nextAt: Date; var runs = 0
    var paused = false; var awaitingReply = false

    var label: String {
        var parts = ["Loop · \(ScheduleInterval.label(interval))"]
        if let timesLeft { parts.append("\(timesLeft) left") }
        if let until { parts.append("until \(until)") }
        return parts.joined(separator: " · ")
    }

    /// What is sent each time; with `--until`, the block the bot ends it with.
    var message: String {
        guard let until else { return prompt }
        return prompt + "\n\n(SwarmHub loop: when this is true — \(until) — end your reply with ```swarmhub\n{\"op\":\"loop\",\"status\":\"done\"}\n``` and the loop stops.)"
    }

    static func loopDone(in text: String) -> Bool {
        SwarmhubBlock.fences(in: text).contains { fence in
            guard let data = fence.body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["op"] as? String == "loop" && object["status"] as? String == "done"
        }
    }

    enum ParseError: Error, Equatable { case noPrompt, badTimes }

    static func parse(_ arguments: String, now: Date) -> Result<LoopRun, ParseError> {
        var words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        var times: Int?; var until: String?
        if let index = words.firstIndex(of: "--until") {
            let end = words[(index + 1)...].firstIndex(of: "--times") ?? words.endIndex
            until = words[(index + 1)..<end].joined(separator: " ").nilIfEmpty
            words.removeSubrange(index..<end)
        }
        if let index = words.firstIndex(of: "--times") {
            guard index + 1 < words.count, let count = Int(words[index + 1]), count > 0 else { return .failure(.badTimes) }
            times = count; words.removeSubrange(index...(index + 1))
        }
        if words.first?.lowercased() == "every" { words.removeFirst() }
        var interval = ScheduleInterval.defaultLoop
        if let (seconds, used) = ScheduleInterval.parse(words) { interval = seconds; words.removeFirst(used) }
        guard let prompt = words.joined(separator: " ").nilIfEmpty else { return .failure(.noPrompt) }
        interval = max(interval, ScheduleInterval.minimum)
        return .success(LoopRun(prompt: prompt, interval: interval, timesLeft: times, until: until, nextAt: now))
    }
}

/// P45 5: `/heartbeat every <interval> [HH:MM–HH:MM] [<prompt>]` — re-enters this chat's own conversation on the schedule,
/// only when it is idle; a reply that is exactly `[SILENT]` is hidden.
struct HeartbeatRun: Codable, Equatable, Sendable {
    static let defaultPrompt = "Heartbeat: check in on what's open and report only if something needs Konrad; otherwise reply [SILENT]"
    var interval: TimeInterval
    /// Minutes after midnight, both ends included; an end before the start runs over midnight.
    var windowStart: Int?; var windowEnd: Int?
    var prompt: String
    var nextAt: Date; var paused = false; var awaitingReply = false
    var runs = 0

    /// "Heartbeat · hourly 08–23".
    var label: String {
        var text = "Heartbeat · \(ScheduleInterval.label(interval))"
        if let windowStart, let windowEnd { text += " \(Self.clock(windowStart))–\(Self.clock(windowEnd))" }
        return text
    }

    func inWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let windowStart, let windowEnd else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return windowStart <= windowEnd ? (windowStart...windowEnd).contains(minute) : minute >= windowStart || minute <= windowEnd
    }

    /// "08" on the hour, else "08:30".
    static func clock(_ minutes: Int) -> String {
        let hour = String(format: "%02d", minutes / 60)
        return minutes % 60 == 0 ? hour : hour + String(format: ":%02d", minutes % 60)
    }

    /// The same `[SILENT]` match as P44's routine results.
    static func isSilent(_ text: String) -> Bool { SilentReply.isSilent(text) }

    enum ParseError: Error, Equatable { case noInterval }

    static func parse(_ arguments: String, now: Date) -> Result<HeartbeatRun, ParseError> {
        var words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first?.lowercased() == "every" { words.removeFirst() }
        guard let (seconds, used) = ScheduleInterval.parse(words) else { return .failure(.noInterval) }
        words.removeFirst(used)
        var start: Int?, end: Int?
        if let first = words.first, let window = window(first) { (start, end) = window; words.removeFirst() }
        let prompt = words.joined(separator: " ").nilIfEmpty ?? defaultPrompt
        let interval = max(seconds, ScheduleInterval.minimum)
        return .success(HeartbeatRun(interval: interval, windowStart: start, windowEnd: end, prompt: prompt, nextAt: now.addingTimeInterval(interval)))
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

enum ScheduleInterval {
    static let minimum: TimeInterval = 60, defaultLoop: TimeInterval = 600

    /// An interval at the start of `words`: "5m", "5 min", "1h", "90s", "2 hours", "hourly", "daily"; and the words it used.
    static func parse(_ words: [String]) -> (TimeInterval, Int)? {
        guard let first = words.first?.lowercased() else { return nil }
        if first == "hourly" { return (3600, 1) }
        if first == "daily" { return (86_400, 1) }
        let digits = first.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value > 0 else { return nil }
        let unit = String(first.dropFirst(digits.count))
        if !unit.isEmpty { return seconds(value, unit: unit).map { ($0, 1) } }
        if words.count > 1, let seconds = seconds(value, unit: words[1].lowercased()) { return (seconds, 2) }
        return nil
    }

    private static func seconds(_ value: Double, unit: String) -> TimeInterval? {
        switch unit {
        case "s", "sec", "secs", "second", "seconds": value
        case "m", "min", "mins", "minute", "minutes": value * 60
        case "h", "hr", "hrs", "hour", "hours": value * 3600
        case "d", "day", "days": value * 86_400
        default: nil
        }
    }

    /// "hourly", "every 2 h", "daily", "every 15 min".
    static func label(_ interval: TimeInterval) -> String {
        if interval == 3600 { return "hourly" }
        if interval == 86_400 { return "daily" }
        if interval.truncatingRemainder(dividingBy: 3600) == 0 { return "every \(Int(interval / 3600)) h" }
        return "every \(Int((interval / 60).rounded())) min"
    }
}

private extension String {
    var nilIfEmpty: String? { let trimmed = trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed }
}
