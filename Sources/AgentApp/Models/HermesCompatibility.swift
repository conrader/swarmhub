import Foundation

/// A Hermes release as `/health` reports it (`"version": "0.21.7"`). Only for showing the box's version and its known
/// issues; features are still picked from `/v1/capabilities`, never by version (PLAN.md).
struct HermesVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int
    init(_ major: Int, _ minor: Int, _ patch: Int) { (self.major, self.minor, self.patch) = (major, minor, patch) }

    var description: String { "\(major).\(minor).\(patch)" }

    /// `0.21.7`, `v0.21.7` or `0.22.0+fleet` → the three numbers; a missing, non-string or malformed value → nil.
    static func parse(_ value: Any?) -> HermesVersion? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let match = text.firstMatch(of: /^[vV]?(\d{1,4})\.(\d{1,4})\.(\d{1,4})(?:[-+ ].*)?$/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return nil }
        return .init(major, minor, patch)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch) }
}

enum HermesSupportStatus: String, Sendable, Equatable {
    case works, notTestedYet, notSupported
    var label: String {
        switch self {
        case .works: "works"
        case .notTestedYet: "not tested yet"
        case .notSupported: "not supported"
        }
    }
}

/// A Hermes bug SwarmHub knows about and shows calmly instead of as an error.
enum HermesKnownIssue: String, CaseIterable, Sendable, Equatable {
    /// `GET /v1/skills` answers 500 "Failed to enumerate skills" for every profile (`include_editorial` passed to `_find_all_skills`).
    case skillsEnumeration = "skills_enumeration"

    var note: String {
        switch self {
        case .skillsEnumeration: "This Hermes version can't list skills (known Hermes bug)"
        }
    }

    /// Whether `error` is this issue's exact symptom; any other failure stays an error.
    func matches(_ error: Error) -> Bool {
        switch self {
        case .skillsEnumeration:
            guard case BackendError.http(500, let message) = error else { return false }
            return message.localizedCaseInsensitiveContains("Failed to enumerate skills")
        }
    }
}

/// The Hermes versions SwarmHub has run against; mirrors `docs/hermes-versions.md` (a test keeps the two equal).
enum HermesCompatibility {
    struct Entry: Sendable, Equatable { let version: HermesVersion; let status: HermesSupportStatus; let issues: Set<HermesKnownIssue> }

    static let versions: [Entry] = [
        .init(version: .init(0, 22, 0), status: .notTestedYet, issues: [.skillsEnumeration]),
        .init(version: .init(0, 21, 7), status: .works, issues: [.skillsEnumeration]),
        .init(version: .init(0, 20, 5), status: .works, issues: [])
    ]

    static func entry(for version: HermesVersion) -> Entry? { versions.first { $0.version == version } }

    /// Listed versions report their own status; anything older than the oldest listed is not supported; any other
    /// version (newer, or between listed ones) is not tested yet.
    static func status(for version: HermesVersion) -> HermesSupportStatus {
        if let entry = entry(for: version) { return entry.status }
        if let oldest = versions.map(\.version).min(), version < oldest { return .notSupported }
        return .notTestedYet
    }

    static func issues(for version: HermesVersion?) -> Set<HermesKnownIssue> { version.flatMap { entry(for: $0)?.issues } ?? [] }

    /// The known issue `error` is the symptom of, only on a version listed with that issue.
    static func limitation(for error: Error, version: HermesVersion?) -> HermesKnownIssue? {
        issues(for: version).sorted { $0.rawValue < $1.rawValue }.first { $0.matches(error) }
    }
}

/// What one connection (server + profile) said its Hermes version is, as last read from `/health`.
struct HermesVersionReading: Sendable, Equatable {
    /// The `version` string as sent, nil when `/health` had none or could not be read (`problem` says why).
    var raw: String?
    var problem: String?

    var version: HermesVersion? { HermesVersion.parse(raw) }
    var status: HermesSupportStatus? { version.map(HermesCompatibility.status(for:)) }

    /// "Hermes 0.21.7 · works", "Hermes 0.22.1 · not tested yet", or why the version is unknown.
    var label: String {
        if let version, let status { return "Hermes \(version) · \(status.label)" }
        if let raw, !raw.isEmpty { return "Hermes \(raw) · version not recognised" }
        return "Hermes version unknown"
    }
}
