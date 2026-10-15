import Foundation

/// P42: what started a turn the user didn't type in a bot's chat: another bot's message (bot-msg or a oneshot command),
/// a routine run, or a late reply delivered back to the bot that asked.
enum BotWorkOrigin: Equatable, Hashable, Sendable {
    case bot(String), routine(String), reply(String)

    /// As kept in a card's metadata: `bot:<profile>`, `routine:<name>`, `reply:<profile>`.
    var raw: String {
        switch self {
        case .bot(let name): "bot:\(name)"
        case .routine(let name): "routine:\(name)"
        case .reply(let name): "reply:\(name)"
        }
    }

    init?(raw: String?) {
        guard let raw, let colon = raw.firstIndex(of: ":") else { return nil }
        let value = String(raw[raw.index(after: colon)...])
        switch raw[..<colon] {
        case "bot": self = .bot(value)
        case "routine": self = .routine(value)
        case "reply": self = .reply(value)
        default: return nil
        }
    }

    /// The bot (profile) on the other side, if a bot started it.
    var profile: String? {
        switch self {
        case .bot(let name), .reply(let name): name
        case .routine: nil
        }
    }

    /// From the first line of the request: `[Message from X via SwarmHub]` or `[Reply from X via SwarmHub]`.
    static func header(_ text: String) -> (origin: BotWorkOrigin, text: String)? {
        for (prefix, make) in [("[Message from ", BotWorkOrigin.bot), ("[Reply from ", BotWorkOrigin.reply)] {
            guard text.hasPrefix(prefix), let end = text.range(of: " via SwarmHub]") else { continue }
            let name = String(text[text.index(text.startIndex, offsetBy: prefix.count)..<end.lowerBound])
            guard !name.isEmpty else { continue }
            return (make(name), String(text[end.upperBound...].drop { $0 == "\n" || $0 == " " }))
        }
        return nil
    }
}

/// The last exchange of a session, read from its rows: the request, the steps so far, and the final reply once there.
struct BotWorkTurn: Equatable, Sendable {
    var requestID: String; var request: String; var origin: BotWorkOrigin?
    var activity: ToolActivity?; var reply: String?; var finished: Bool; var startedAt: Date?

    /// Changes whenever a row lands (the back-off restarts from it).
    var signature: String { "\(requestID)|\(activity?.total ?? 0)|\(reply?.count ?? -1)|\(finished)" }
}

enum BotWorkReader {
    /// The session's last turn (a user row and what followed it); nil when there is none, or when it began before
    /// `after` (the request a step just sent has not landed yet). A turn is finished when its last assistant row has
    /// text and no tool calls, or the model ended it with an error; until then its newest step counts as running.
    static func lastTurn(_ rows: [BackendMessage], after: Date? = nil) -> BotWorkTurn? {
        let turns = HistoryReconciler.serverTurns(rows)
        guard let turn = turns.last, let user = turn.user else { return nil }
        if let after, let created = user.createdAt, created < after { return nil }
        let header = BotWorkOrigin.header(user.content)
        let last = turn.rows.last
        let finished = last.map { $0.tools.isEmpty && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false || turn.endedWithError
        var activity = turn.activity
        // A step lasts until the next one starts (the box stamps only the call); the newest one until the reply, or it
        // still runs.
        if var timed = activity {
            for index in timed.steps.indices.dropLast() { timed.steps[index].finishedAt = timed.steps[index + 1].startedAt }
            if let index = timed.steps.indices.last { timed.steps[index].finishedAt = finished ? last?.createdAt ?? timed.steps[index].startedAt : nil }
            timed.endedAt = finished ? timed.steps.last?.finishedAt : nil
            activity = timed
        }
        let reply = finished ? last?.content.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return BotWorkTurn(requestID: user.id.map(String.init) ?? "t\(turn.index)", request: header?.text ?? user.content, origin: header?.origin,
                           activity: activity, reply: reply.flatMap { $0.isEmpty ? nil : $0 }, finished: finished, startedAt: user.createdAt)
    }
}

/// How often a live card reads its session: every 2 s, every 10 s after a minute without a change, never past 30 min.
enum BotWorkSchedule {
    static let fast: Duration = .seconds(2), slow: Duration = .seconds(10)
    static let slowAfter: TimeInterval = 60, limit: TimeInterval = 1_800
    /// A thread changed this recently is checked for a run still going (after a restart, or a list without a sender step).
    static let recent: TimeInterval = 1_800
    /// Reads that fail in a row before the card stops.
    static let failures = 3

    static func interval(sinceChange: TimeInterval) -> Duration { sinceChange >= slowAfter ? slow : fast }
}

/// Where a live card's session is: known (`swarmhub-from-<sender>`), or the newest of a source started after a time
/// (a oneshot command's session, a routine run's `cron_<job>_<time>` session).
enum BotWorkTarget: Hashable, Sendable {
    case session(String)
    case newest(source: String, prefix: String?, after: Date)

    var key: String {
        switch self {
        case .session(let id): id
        case .newest(let source, let prefix, let after): "?\(source)|\(prefix ?? "")|\(Int(after.timeIntervalSince1970))"
        }
    }

    /// The session in a list: the newest of `source` (and `prefix`) started at or after `after` (5 s of clock slack).
    func pick(_ rows: [BotSessionRow]) -> String? {
        guard case .newest(let source, let prefix, let after) = self else { return nil }
        return rows.filter { row in
            (row.source == nil || row.source == source) && (prefix.map { row.id.hasPrefix($0) } ?? true)
                && (row.startedAt.map { $0 >= after.addingTimeInterval(-5) } ?? false)
        }.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }?.id
    }
}

enum BotWorkKey {
    static let origin = "botWork.origin", request = "botWork.request", requestID = "botWork.requestID", reply = "botWork.reply"
}

enum BotWorkCopy {
    /// "Woken by: Jarvis", "Woken by: routine Morning report", "Woken by: reply from Infra".
    static func wokenBy(_ origin: BotWorkOrigin, name: (String) -> String) -> String {
        switch origin {
        case .bot(let profile): "Woken by: \(name(profile))"
        case .routine(let routine): "Woken by: routine \(routine)"
        case .reply(let profile): "Woken by: reply from \(name(profile))"
        }
    }

    /// The sidebar row and chat header while it works: "Working… · for Jarvis".
    static func working(_ origin: BotWorkOrigin, name: (String) -> String) -> String {
        let label = ChatActivityPhase.working.label
        switch origin {
        case .bot(let profile): return "\(label) · for \(name(profile))"
        case .routine(let routine): return "\(label) · routine \(routine)"
        case .reply(let profile): return "\(label) · reply from \(name(profile))"
        }
    }

    /// The card's title while it runs.
    static func workingFor(_ origin: BotWorkOrigin, name: (String) -> String) -> String {
        switch origin {
        case .bot(let profile): "Working for \(name(profile))"
        case .routine(let routine): "Running routine \(routine)"
        case .reply(let profile): "Reading the reply from \(name(profile))"
        }
    }

    static func from(_ name: String) -> String { "From \(name)" }
    static let stopped = "Stopped watching after 30 min; the conversation has the rest."
}
