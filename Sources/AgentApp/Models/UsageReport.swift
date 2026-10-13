import Foundation

/// Token and message counts of one Hermes session row from `GET /api/sessions` (`_session_response`:
/// `started_at`, `ended_at`, `message_count`, `input_tokens`, `output_tokens`, `cache_read_tokens`,
/// `reasoning_tokens`, …). Missing or null counters read as 0.
struct SessionUsage: Equatable, Sendable {
    var id: String
    var startedAt: Date?
    var endedAt: Date?
    var messages = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var reasoningTokens = 0

    static func parse(_ row: [String: Any]) -> SessionUsage? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        return SessionUsage(
            id: id, startedAt: date(row["started_at"]), endedAt: date(row["ended_at"]),
            messages: count(row["message_count"]), inputTokens: count(row["input_tokens"]), outputTokens: count(row["output_tokens"]),
            cacheReadTokens: count(row["cache_read_tokens"]), reasoningTokens: count(row["reasoning_tokens"])
        )
    }

    /// Integers, whole doubles and numeric strings; anything else (null, negative, text) is 0.
    static func count(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return max(0, number.intValue)
        case let text as String: return max(0, Int(text) ?? 0)
        default: return 0
        }
    }

    /// Hermes stores `started_at` as Unix seconds (a float); milliseconds and ISO 8601 strings are accepted too.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let seconds = number.doubleValue
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let seconds = Double(text) { return date(NSNumber(value: seconds)) }
        let formatter = ISO8601DateFormatter()
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

enum UsageWindow: String, CaseIterable, Identifiable, Sendable {
    case day = "Last 24 h", week = "Last 7 days", all = "All time"
    var id: String { rawValue }

    /// A session counts in a window when it started inside it; sessions without a start time count only in All.
    func includes(_ session: SessionUsage, now: Date) -> Bool {
        switch self {
        case .all: true
        case .day: session.startedAt.map { $0 > now.addingTimeInterval(-86_400) && $0 <= now } ?? false
        case .week: session.startedAt.map { $0 > now.addingTimeInterval(-7 * 86_400) && $0 <= now } ?? false
        }
    }
}

struct UsageTotals: Equatable, Sendable {
    var sessions = 0, messages = 0, inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, reasoningTokens = 0
    var totalTokens: Int { inputTokens + outputTokens }

    static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(sessions: lhs.sessions + rhs.sessions, messages: lhs.messages + rhs.messages, inputTokens: lhs.inputTokens + rhs.inputTokens,
                    outputTokens: lhs.outputTokens + rhs.outputTokens, cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens, reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens)
    }

    /// Sums the sessions in `window`; a session id seen twice (pages shifting while reading) counts once.
    static func of(_ sessions: [SessionUsage], window: UsageWindow, now: Date = .now) -> UsageTotals {
        var seen: Set<String> = []; var totals = UsageTotals()
        for session in sessions where window.includes(session, now: now) && seen.insert(session.id).inserted {
            totals.sessions += 1; totals.messages += session.messages
            totals.inputTokens += session.inputTokens; totals.outputTokens += session.outputTokens
            totals.cacheReadTokens += session.cacheReadTokens; totals.reasoningTokens += session.reasoningTokens
        }
        return totals
    }
}

/// Usage of one Hermes profile (the bots bound to it share it), or why it could not be read.
struct ProfileUsage: Identifiable, Sendable {
    var id: String { "\(server)|\(profile)" }
    var botNames: [String]
    var profile: String
    var server: String
    var sessions: [SessionUsage] = []
    /// More sessions exist than were read (page cap reached).
    var truncated = false
    var problem: String?

    var label: String { botNames.joined(separator: ", ") }
    func totals(_ window: UsageWindow, now: Date = .now) -> UsageTotals { UsageTotals.of(sessions, window: window, now: now) }

    static func total(_ rows: [ProfileUsage], window: UsageWindow, now: Date = .now) -> UsageTotals {
        rows.reduce(UsageTotals()) { $0 + $1.totals(window, now: now) }
    }

    /// "1.2k", "3.4M" — compact token counts for the table and bars.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: "%.1fk", Double(value) / 1_000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }
}
