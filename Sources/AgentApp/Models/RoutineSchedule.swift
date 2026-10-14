import Foundation

/// Schedule presets of the routine editor (P21b: a plain picker; raw text under Advanced). Hermes takes a cron expression
/// (`minute hour day month weekday`, evaluated in the server's configured timezone), `every <N>m|h|d`, a duration
/// (one-shot) or an ISO timestamp — `cron/jobs.py` `parse_schedule`. No time zone conversion happens on the Mac.
enum RoutinePreset: String, CaseIterable, Identifiable, Sendable {
    case daily = "Daily", weekdays = "Weekdays", weekly = "Weekly", everyHours = "Every N hours", custom = "Custom"
    var id: String { rawValue }
    /// What the picker offers; `custom` shows only for a schedule it cannot express.
    static let pickable: [RoutinePreset] = [.daily, .weekdays, .weekly, .everyHours]
}

struct RoutineScheduleDraft: Equatable, Sendable {
    var preset: RoutinePreset = .daily
    var hour = 9, minute = 0
    /// Cron weekday: 0 = Sunday … 6 = Saturday.
    var weekday = 1
    /// Every N hours, on the hour; only divisors of 24 so every gap is the same length.
    var everyHours = 1
    var custom = ""

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let hourSteps = [1, 2, 3, 4, 6, 8, 12]

    var expression: String {
        switch preset {
        case .daily: "\(minute) \(hour) * * *"
        case .weekdays: "\(minute) \(hour) * * 1-5"
        case .weekly: "\(minute) \(hour) * * \(weekday)"
        case .everyHours: everyHours == 1 ? "0 * * * *" : "0 */\(everyHours) * * *"
        case .custom: custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    init() {}

    /// Recognises the expressions the presets write (leniently: `7` for Sunday, any `*/N` hour step); anything else
    /// is Custom with the text unchanged. Used to describe a schedule; the editor uses `init(editing:)`.
    init(parsing schedule: String) {
        let text = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        custom = text
        guard let parts = Self.cronParts(text) else { preset = .custom; return }
        if parts[0] == "0", parts[2] == "*", parts[3] == "*", parts[4] == "*" {
            if parts[1] == "*" { preset = .everyHours; everyHours = 1; return }
            if parts[1].hasPrefix("*/"), let step = Int(parts[1].dropFirst(2)), (1..<24).contains(step) { preset = .everyHours; everyHours = step; return }
        }
        guard parts[2] == "*", parts[3] == "*", let minute = Int(parts[0]), let hour = Int(parts[1]), (0..<60).contains(minute), (0..<24).contains(hour) else { preset = .custom; return }
        self.hour = hour; self.minute = minute
        switch parts[4] {
        case "*": preset = .daily
        case "1-5": preset = .weekdays
        case let day where Int(day).map({ (0...7).contains($0) }) == true: preset = .weekly; weekday = Int(day)! % 7
        default: preset = .custom
        }
    }

    /// The editor's reading (P21b item 2): the picker shows a schedule only when writing it back gives exactly the same
    /// text; anything else (`0 9 * * 7`, `00 09 * * *`, `every 30m`, a 6-field line) is Custom with `custom` kept as given.
    init(editing schedule: String) {
        self.init(parsing: schedule)
        custom = schedule
        let exact = preset != .everyHours || Self.hourSteps.contains(everyHours)
        if preset != .custom, !exact || expression != schedule.trimmingCharacters(in: .whitespacesAndNewlines) { preset = .custom }
    }

    /// The time picker's value for `hour:minute` and back, in `calendar`'s time zone both ways, so the numbers written
    /// into the schedule are the ones shown (the box applies its own time zone, as before).
    static func pickerDate(hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? .now
    }
    static func pickerTime(_ date: Date, calendar: Calendar = .current) -> (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0, parts.minute ?? 0)
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
            case .everyHours: return draft.everyHours == 1 ? "Every hour" : "Every \(draft.everyHours) hours"
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

/// The routine editor's schedule (P21b item 2): the picker's draft and the raw text under Advanced, kept in step. A pick
/// rewrites the raw text; typing raw text re-reads the picker and keeps the text exactly as typed.
struct RoutineScheduleEditor: Equatable, Sendable {
    private(set) var draft: RoutineScheduleDraft
    private(set) var raw: String
    /// A stored schedule the picker cannot show opens with Advanced unfolded.
    let opensAdvanced: Bool

    init(schedule: String?) {
        if let schedule { draft = RoutineScheduleDraft(editing: schedule); raw = schedule }
        else { draft = RoutineScheduleDraft(); raw = draft.expression }
        opensAdvanced = draft.preset == .custom
    }

    /// What Save sends: the picker's expression, or the raw text trimmed (as before P21b).
    var expression: String { draft.preset == .custom ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : draft.expression }

    mutating func setRaw(_ text: String) { raw = text; draft = RoutineScheduleDraft(editing: text) }

    /// A change made with the picker; choosing a preset while Custom starts from the draft's last time and day.
    mutating func pick(_ change: (inout RoutineScheduleDraft) -> Void) {
        change(&draft)
        if draft.preset != .custom { raw = draft.expression }
    }
}
