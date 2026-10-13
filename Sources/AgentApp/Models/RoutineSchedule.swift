import Foundation

/// Schedule presets of the routine editor. Hermes takes a cron expression (`minute hour day month weekday`, evaluated in
/// the server's configured timezone), `every <N>m|h|d`, a duration (one-shot) or an ISO timestamp — `cron/jobs.py` `parse_schedule`.
enum RoutinePreset: String, CaseIterable, Identifiable, Sendable {
    case hourly = "Hourly", daily = "Daily", weekdays = "Weekdays", weekly = "Weekly", custom = "Custom"
    var id: String { rawValue }
}

struct RoutineScheduleDraft: Equatable, Sendable {
    var preset: RoutinePreset = .daily
    var hour = 9, minute = 0
    /// Cron weekday: 0 = Sunday … 6 = Saturday.
    var weekday = 1
    var custom = ""

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var expression: String {
        switch preset {
        case .hourly: "0 * * * *"
        case .daily: "\(minute) \(hour) * * *"
        case .weekdays: "\(minute) \(hour) * * 1-5"
        case .weekly: "\(minute) \(hour) * * \(weekday)"
        case .custom: custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    init() {}

    /// Recognises the expressions the presets write; anything else opens as Custom with the text unchanged.
    init(parsing schedule: String) {
        let text = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        custom = text
        guard let parts = Self.cronParts(text) else { preset = .custom; return }
        if parts == ["0", "*", "*", "*", "*"] { preset = .hourly; return }
        guard parts[2] == "*", parts[3] == "*", let minute = Int(parts[0]), let hour = Int(parts[1]), (0..<60).contains(minute), (0..<24).contains(hour) else { preset = .custom; return }
        self.hour = hour; self.minute = minute
        switch parts[4] {
        case "*": preset = .daily
        case "1-5": preset = .weekdays
        case let day where Int(day).map({ (0...7).contains($0) }) == true: preset = .weekly; weekday = Int(day)! % 7
        default: preset = .custom
        }
    }

    static func cronParts(_ text: String) -> [String]? {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 5, parts.allSatisfy({ $0.allSatisfy { "0123456789*-,/".contains($0) } }) else { return nil }
        return parts
    }

    /// "Daily at 09:00", "Weekdays at 08:30", "Mondays at 07:15", "Every hour", "Every 30 min"; other text is shown as is.
    static func describe(_ schedule: String) -> String {
        let text = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("every "), let minutes = intervalMinutes(String(text.dropFirst(6))) {
            if minutes % 1440 == 0 { return minutes == 1440 ? "Every day" : "Every \(minutes / 1440) days" }
            if minutes % 60 == 0 { return minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours" }
            return "Every \(minutes) min"
        }
        if cronParts(text) != nil {
            let draft = RoutineScheduleDraft(parsing: text)
            let time = String(format: "%02d:%02d", draft.hour, draft.minute)
            switch draft.preset {
            case .hourly: return "Every hour"
            case .daily: return "Daily at \(time)"
            case .weekdays: return "Weekdays at \(time)"
            case .weekly: return "\(weekdayNames[draft.weekday])s at \(time)"
            case .custom: return "Cron \(text)"
            }
        }
        if let date = RoutineTime.date(text) { return "Once at \(date.formatted(date: .abbreviated, time: .shortened))" }
        return text
    }

    private static func intervalMinutes(_ text: String) -> Int? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = lower.prefix { $0.isNumber }
        guard let value = Int(digits) else { return nil }
        switch lower.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).first {
        case "m": return value
        case "h": return value * 60
        case "d": return value * 1440
        default: return nil
        }
    }
}

/// Hermes writes times with `datetime.isoformat()`: offset-aware, often with microseconds.
enum RoutineTime {
    static func date(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "T")
        if let dot = value.firstIndex(of: ".") {
            let end = value[dot...].dropFirst().firstIndex { !$0.isNumber } ?? value.endIndex
            value.removeSubrange(dot..<end)
        }
        let withZone = ISO8601DateFormatter(); withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: value) { return date }
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: value) ?? { local.dateFormat = "yyyy-MM-dd'T'HH:mm"; return local.date(from: value) }()
    }

    /// "in 5 minutes", "2 hours ago"; `nil` when there is no time.
    static func relative(_ text: String?, now: Date = .now) -> String? {
        guard let text, let date = date(text) else { return nil }
        if abs(date.timeIntervalSince(now)) < 60 { return date > now ? "in under a minute" : "just now" }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// `true` when `new` is a later run than `old` (string inequality when either does not parse).
    static func isLater(_ new: String, than old: String) -> Bool {
        guard new != old else { return false }
        guard !old.isEmpty else { return true }
        guard let newDate = date(new), let oldDate = date(old) else { return true }
        return newDate > oldDate
    }
}
