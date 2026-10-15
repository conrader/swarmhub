import Foundation

/// P36: what a report is about.
enum ReportKind: String, Codable, CaseIterable, Sendable {
    case bug, feature
    var label: String { self == .bug ? "Bug" : "Feature request" }
}

/// P36: one report file on a box as the listing turn returns it (`~/.hermes/swarmhub/reports/<id>.json`, written by
/// the swarmhub-feedback skill's `swarmhub-report`). Nil for a row without a valid id, kind, title or body.
struct BoxReport: Equatable, Sendable {
    var id: String; var kind: ReportKind; var title: String; var body: String
    var bot: String?; var botBackend: String?; var skillVersions: [String: String] = [:]; var hermesVersion: String?; var createdAt: Date?

    init(id: String, kind: ReportKind, title: String, body: String, bot: String? = nil, botBackend: String? = nil,
         skillVersions: [String: String] = [:], hermesVersion: String? = nil, createdAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.bot = bot; self.botBackend = botBackend
        self.skillVersions = skillVersions; self.hermesVersion = hermesVersion; self.createdAt = createdAt
    }

    init?(_ row: [String: Any]) {
        func string(_ key: String) -> String? { (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let id = string("id"), SwarmReport.isValidLocalID(id), let kind = string("kind").flatMap(ReportKind.init(rawValue:)),
              let title = string("title"), !title.isEmpty, let body = row["body"] as? String, !body.isEmpty else { return nil }
        self.id = id; self.kind = kind
        self.title = String(title.prefix(SwarmReport.titleLimit)); self.body = String(body.prefix(SwarmReport.bodyLimit))
        bot = string("bot").flatMap { HermesKeyPaste.isValidProfileName($0) ? $0 : nil }
        botBackend = string("bot_backend").flatMap { SwarmReport.isPlainWord($0) ? $0 : nil }
        skillVersions = SwarmReport.cleanVersions(row["skill_versions"] as? [String: Any] ?? [:])
        hermesVersion = string("hermes_version").flatMap { SwarmReport.isPlainWord($0) ? $0 : nil }
        createdAt = string("created_at").flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// P36: one report in the Reports inbox: a bot's (from its swarmhub block and the box's file) or Konrad's own.
/// Nothing leaves the Mac until Send; the box file is renamed `.sent` (or deleted on Dismiss) by the manager.
struct SwarmReport: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case agent, user }
    enum State: String, Codable, Sendable { case pending, sent, dismissed }
    /// What the box still has to do with the report's file.
    enum BoxFile: String, Codable, Sendable { case none, present, markSent, delete, closed }

    static let titleLimit = 140, bodyLimit = 8000, versionsLimit = 20

    var id: String
    var source: Source
    var kind: ReportKind
    var title: String
    var body: String
    /// The bot's profile (agent reports) and the connection its manager runs on.
    var bot: String?; var connection: String?
    var botBackend: String?
    var skillVersions: [String: String] = [:]
    var hermesVersion: String?; var appVersion: String?
    var createdAt: Date
    var state: State = .pending
    var boxFile: BoxFile = .none
    /// False while only the swarmhub op is known (the listing turn brings the body).
    var hasBody = true
    var serverID: String?; var status: String?; var note: String?; var updatedAt: Date?

    /// Local ids `swarmhub-report` makes (`r<stamp>-<hex>`) and the app's own (`u-<uuid>`).
    static func isValidLocalID(_ text: String) -> Bool {
        (2...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isPlainWord(_ text: String) -> Bool {
        (1...40).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".+-_".contains($0)) }
    }

    /// Skill name → semver, valid pairs only, at most `versionsLimit` (by name).
    static func cleanVersions(_ raw: [String: Any]) -> [String: String] {
        let pairs = raw.compactMap { name, value -> (String, String)? in
            guard HermesKeyPaste.isValidProfileName(name), let version = (value as? String).flatMap(SkillVersion.init) else { return nil }
            return (name, version.description)
        }.sorted { $0.0 < $1.0 }.prefix(versionsLimit)
        return Dictionary(uniqueKeysWithValues: Array(pairs))
    }

    var isAwaitingBox: Bool { boxFile == .markSent || boxFile == .delete }
}

/// P36: a report as `GET /v1/reports` lists it.
struct ServerReport: Equatable, Sendable {
    var id: String; var kind: String; var title: String; var status: String; var note: String?; var createdAt: Date?; var updatedAt: Date?

    init(id: String, kind: String = "bug", title: String = "", status: String, note: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.status = status; self.note = note; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init?(_ row: [String: Any]) {
        guard let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init), let status = row["status"] as? String else { return nil }
        self.init(id: id, kind: row["kind"] as? String ?? "", title: row["title"] as? String ?? "", status: status,
                  note: (row["note"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  createdAt: SwarmHubDates.parse(row["created_at"]), updatedAt: SwarmHubDates.parse(row["updated_at"]))
    }
}

/// P36: the inbox's state machine, pure so tests drive it: pending (op, then body) → sent → status updated; dismissed.
struct ReportsInbox: Codable, Equatable, Sendable {
    var reports: [SwarmReport] = []

    /// Newest first; dismissed ones are gone from the list (their box file may still be waiting to be deleted).
    var visible: [SwarmReport] { reports.filter { $0.state != .dismissed }.sorted { $0.createdAt > $1.createdAt } }
    var pendingCount: Int { reports.filter { $0.state == .pending }.count }

    func report(_ id: String) -> SwarmReport? { reports.first { $0.id == id } }

    /// A `report` op from a bot's reply: a pending row until the listing brings its body.
    mutating func absorbOp(id: String, kind: ReportKind, title: String, bot: String?, connection: String, now: Date) {
        guard report(id) == nil else { return }
        reports.append(SwarmReport(id: id, source: .agent, kind: kind, title: title, body: "", bot: bot, connection: connection,
                                   botBackend: "hermes", createdAt: now, boxFile: .present, hasBody: false))
    }

    /// The listing's unsent files. A known pending row gets the body and facts (Konrad's edits stay); a file of a sent
    /// or dismissed report is closed again; an unknown file is a new pending row.
    mutating func absorbBox(_ rows: [BoxReport], connection: String, now: Date) {
        for row in rows {
            if let index = reports.firstIndex(where: { $0.id == row.id }) {
                switch reports[index].state {
                case .pending:
                    var report = reports[index]
                    if !report.hasBody { report.body = row.body; report.title = row.title; report.hasBody = true; report.createdAt = row.createdAt ?? report.createdAt }
                    report.bot = report.bot ?? row.bot; report.botBackend = row.botBackend ?? report.botBackend
                    report.skillVersions = row.skillVersions; report.hermesVersion = row.hermesVersion; report.boxFile = .present
                    reports[index] = report
                case .sent: if reports[index].boxFile != .markSent { reports[index].boxFile = .markSent }
                case .dismissed: reports[index].boxFile = .delete
                }
            } else {
                reports.append(SwarmReport(id: row.id, source: .agent, kind: row.kind, title: row.title, body: row.body, bot: row.bot, connection: connection,
                                           botBackend: row.botBackend, skillVersions: row.skillVersions, hermesVersion: row.hermesVersion,
                                           createdAt: row.createdAt ?? now, boxFile: .present))
            }
        }
    }

    mutating func add(_ report: SwarmReport) { reports.removeAll { $0.id == report.id }; reports.append(report) }

    mutating func edit(_ id: String, title: String, body: String) {
        guard let index = reports.firstIndex(where: { $0.id == id }), reports[index].state == .pending else { return }
        reports[index].title = String(title.prefix(SwarmReport.titleLimit)); reports[index].body = String(body.prefix(SwarmReport.bodyLimit))
        reports[index].hasBody = true
    }

    /// Posted: the server's id and status; a box file is to be renamed `.sent`.
    mutating func markSent(_ id: String, serverID: String, status: String, now: Date) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[index].state = .sent; reports[index].serverID = serverID; reports[index].status = status; reports[index].updatedAt = now
        if reports[index].boxFile == .present { reports[index].boxFile = .markSent }
    }

    /// Dismiss: a report without a box file goes at once; one with a file waits until the manager deleted it.
    mutating func dismiss(_ id: String) {
        guard let index = reports.firstIndex(where: { $0.id == id }), reports[index].state == .pending else { return }
        if reports[index].boxFile == .none || reports[index].boxFile == .closed { reports.remove(at: index); return }
        reports[index].state = .dismissed; reports[index].boxFile = .delete
    }

    /// The ids the box still has to rename (`sent`) or delete, per connection.
    func boxWork(on connection: String) -> (sent: [String], deleted: [String]) {
        let mine = reports.filter { $0.connection == connection }
        return (mine.filter { $0.boxFile == .markSent }.map(\.id), mine.filter { $0.boxFile == .delete }.map(\.id))
    }

    var connectionsWithBoxWork: [String] { Array(Set(reports.filter(\.isAwaitingBox).compactMap(\.connection))).sorted() }

    /// `reports_closed`: the files are handled; dismissed rows are forgotten.
    mutating func boxClosed(sent: [String], deleted: [String]) {
        for index in reports.indices where sent.contains(reports[index].id) && reports[index].boxFile == .markSent { reports[index].boxFile = .closed }
        reports.removeAll { deleted.contains($0.id) && $0.state == .dismissed }
        for index in reports.indices where deleted.contains(reports[index].id) { reports[index].boxFile = .closed }
    }

    /// `GET /v1/reports`: the status and note of every sent report the server knows.
    mutating func applyStatuses(_ rows: [ServerReport]) {
        for row in rows {
            guard let index = reports.firstIndex(where: { $0.serverID == row.id }) else { continue }
            reports[index].status = row.status; reports[index].note = row.note
            reports[index].updatedAt = row.updatedAt ?? reports[index].updatedAt
        }
    }
}

/// P36: "Report a problem…": a user report prefilled with the app and macOS versions and the kinds of connection.
/// Never keys, addresses or bot names (Konrad adds those himself if he wants).
enum ReportPrefill {
    static func body(appVersion: String, macOS: String, connectionKinds: [String]) -> String {
        let kinds = connectionKinds.isEmpty ? "none" : connectionKinds.joined(separator: ", ")
        return "What happened:\n\n\nWhat I expected:\n\n\n—\n\(AppConstants.name) \(appVersion) · macOS \(macOS) · connections: \(kinds)"
    }

    static func macOSVersion(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }

    static func make(appVersion: String, macOS: String, connectionKinds: [String], now: Date) -> SwarmReport {
        SwarmReport(id: "u-\(UUID().uuidString.lowercased())", source: .user, kind: .bug, title: "",
                    body: body(appVersion: appVersion, macOS: macOS, connectionKinds: connectionKinds), appVersion: appVersion, createdAt: now)
    }
}

enum SwarmHubDates {
    /// ISO 8601 (with or without fractions) or epoch seconds.
    static func parse(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text) ?? Double(text).map(Date.init(timeIntervalSince1970:))
    }
}
