import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Herdr server's skill library, as its workspace reports it (`GET /api/skillshare`). skillshare is a program on
/// the server that keeps one folder of agent skills and links it into each agent program's own skills folder, a
/// Target. The workspace keeps no copy: every answer is what skillshare says at that moment. Turning a skill on or
/// off changes the library only; the agent programs get the change with the next sync. The app installs no skills.
/// Foundation only, like the rest of the Herdr client.
struct HerdrSkillLibrary: Decodable, Sendable, Equatable {
    struct Skill: Decodable, Sendable, Equatable, Identifiable {
        /// The name skillshare lists it under, and the name a switch sends back.
        let name: String
        /// Its folder inside the library; two skills may share a name, never a folder.
        var path: String? = nil
        /// The start of the description in its `SKILL.md`, when it has one.
        var description: String? = nil
        var enabled: Bool
        /// `local`, `tracked`, or the kind of place it was installed from.
        var origin: String? = nil
        var source: String? = nil
        var id: String { path ?? name }
    }

    /// One agent program's skills folder the library is linked into.
    struct Target: Decodable, Sendable, Equatable, Identifiable {
        let name: String
        var path: String? = nil
        var mode: String? = nil
        /// skillshare's word for the folder's state, such as `merged` or `not exist`.
        var status: String? = nil
        /// Skills of the library that are in the folder now.
        var linked: Int? = nil
        var skillsEnabled: Bool? = nil
        var id: String { name }

        /// "codex (50 skills)", "codex (skills off)", or with nothing linked the state skillshare reports.
        var line: String {
            if skillsEnabled == false { return "\(name) (skills off)" }
            let count = linked ?? 0
            if count == 0, let status, !status.isEmpty, status != "merged" { return "\(name) (\(status))" }
            return "\(name) (\(HerdrSkillLibrary.skills(count)))"
        }
    }

    var installed: Bool
    var version: String? = nil
    /// Why the rest is missing or may be incomplete, in the server's words; nil when all is well.
    var problem: String? = nil
    /// The folder skillshare keeps the skills in.
    var source: String? = nil
    /// Every skill in the library; `skills` holds the first of them when there are more than an answer carries.
    var skillCount: Int? = nil
    var skills: [Skill] = []
    var targets: [Target] = []
    /// After a switch: the skills whose state changed, and what skillshare said.
    var changed: [String]? = nil
    var output: String? = nil

    enum CodingKeys: CodingKey { case installed, version, problem, source, skillCount, skills, targets, changed, output }
    init(installed: Bool, version: String? = nil, problem: String? = nil, source: String? = nil, skillCount: Int? = nil, skills: [Skill] = [], targets: [Target] = []) {
        self.installed = installed; self.version = version; self.problem = problem; self.source = source; self.skillCount = skillCount; self.skills = skills; self.targets = targets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version); problem = try c.decodeIfPresent(String.self, forKey: .problem)
        source = try c.decodeIfPresent(String.self, forKey: .source); skillCount = try c.decodeIfPresent(Int.self, forKey: .skillCount)
        skills = try c.decodeIfPresent([Skill].self, forKey: .skills) ?? []; targets = try c.decodeIfPresent([Target].self, forKey: .targets) ?? []
        changed = try c.decodeIfPresent([String].self, forKey: .changed); output = try c.decodeIfPresent(String.self, forKey: .output)
    }

    static func skills(_ count: Int) -> String { count == 1 ? "1 skill" : "\(count) skills" }

    var enabledCount: Int { skills.filter(\.enabled).count }
    /// More skills than one answer carries: the list shows the first of them.
    var hiddenCount: Int { max(0, (skillCount ?? skills.count) - skills.count) }

    /// The skills whose name or description holds `query`, in the server's order; all of them for an empty query.
    func matching(_ query: String) -> [Skill] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return skills }
        return skills.filter { $0.name.localizedCaseInsensitiveContains(needle) || ($0.description?.localizedCaseInsensitiveContains(needle) ?? false) }
    }

    /// Which agent programs get these skills, by skillshare's own names: "Shared with codex (50 skills) and universal (50 skills)."
    var sharedLine: String {
        guard !targets.isEmpty else { return "Not shared with any agent program yet, so no agent gets these skills." }
        return "Shared with \(Self.list(targets.map(\.line)))."
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

/// What a sync did, or with `dryRun` what it would do (`POST /api/skillshare/sync`): the numbers for all Targets, the
/// same for each one in `details`, and the Targets as they are afterwards.
struct HerdrSkillSync: Decodable, Sendable, Equatable {
    struct Detail: Decodable, Sendable, Equatable {
        let name: String
        var linked: Int? = nil; var local: Int? = nil; var updated: Int? = nil; var pruned: Int? = nil
    }
    var dryRun: Bool? = nil
    var linked: Int? = nil; var local: Int? = nil; var updated: Int? = nil; var pruned: Int? = nil; var ignored: Int? = nil
    var details: [Detail]? = nil
    var targets: [HerdrSkillLibrary.Target]? = nil
    var problem: String? = nil

    /// Of a dry run: a sync would change something, so the agent programs are not up to date with the library. A link
    /// would be removed, or a Target would hold another number of the library's skills than it holds now.
    var isPending: Bool {
        if (pruned ?? 0) > 0 { return true }
        return (details ?? []).contains { detail in
            guard let target = targets?.first(where: { $0.name == detail.name }) else { return false }
            return (detail.pruned ?? 0) > 0 || detail.linked != target.linked
        }
    }

    /// "codex (49 skills) and universal (49 skills)", from the Targets as the sync left them.
    var targetsLine: String { HerdrSkillLibrary.list((targets ?? []).map(\.line)) }
}

/// The Targets alone (`GET` and `POST /api/skillshare/targets`), and after adding one what was added.
struct HerdrSkillTargets: Decodable, Sendable, Equatable {
    var installed: Bool? = nil
    var problem: String? = nil
    var targets: [HerdrSkillLibrary.Target]? = nil
    var added: String? = nil
    var output: String? = nil
}

/// The agent programs skillshare finds on the server and does not link into yet (`GET /api/skillshare/targets/addable`).
struct HerdrSkillAddable: Decodable, Sendable, Equatable {
    var installed: Bool? = nil
    var problem: String? = nil
    var agents: [String]? = nil
}

extension HerdrClient {
    /// The server stops skillshare after 20 seconds for a read, 60 for a change and 120 for a sync, and says so. The
    /// client waits a little longer, so that the server's own sentence arrives instead of a silent timeout here.
    static let skillReadSeconds: TimeInterval = 35, skillChangeSeconds: TimeInterval = 80, skillSyncSeconds: TimeInterval = 140

    func skillLibrary() async throws -> HerdrSkillLibrary { try await get("/api/skillshare", timeout: Self.skillReadSeconds) }

    /// Turns one skill on or off in the library. The agent programs see it after `syncSkills`.
    func setSkill(_ name: String, enabled: Bool) async throws -> HerdrSkillLibrary {
        try await post("/api/skillshare/\(enabled ? "enable" : "disable")", ["name": name], timeout: Self.skillChangeSeconds)
    }

    /// Links the enabled skills into every Target and removes the links of disabled ones; `dryRun` changes nothing and
    /// reports what a sync would do.
    func syncSkills(dryRun: Bool = false) async throws -> HerdrSkillSync {
        try await post("/api/skillshare/sync", dryRun ? ["dry_run": true] : [:], timeout: dryRun ? Self.skillReadSeconds : Self.skillSyncSeconds)
    }

    /// The agent programs the library could also be shared with. The server runs a discovery to answer, so this is
    /// asked only when the person opens that control, never on a refresh.
    func skillTargetsAddable() async throws -> HerdrSkillAddable { try await get("/api/skillshare/targets/addable", timeout: Self.skillReadSeconds) }

    /// Makes one agent program a Target. This only writes skillshare's configuration: nothing is linked into the
    /// program's folder until the next sync, and from then on every session of that program on the server gets the skills.
    func addSkillTarget(_ agent: String) async throws -> HerdrSkillTargets {
        try await post("/api/skillshare/targets", ["agent": agent], timeout: Self.skillChangeSeconds)
    }
}

/// What the Skills section says, apart from the server's own sentences.
enum HerdrSkillsCopy {
    static let olderWorkspace = "This server's Herdr workspace is older and has no skill library. Update swarmhub-herdr on the server, then read again."
    static let runningAgents = "An agent that is already running keeps the skills it started with until it starts afresh."
    static let empty = "The library has no skills yet. Skills are added with skillshare on the server."
    static let notUpToDate = "The agent programs are not up to date with the library."
    static func more(_ hidden: Int) -> String { "\(HerdrSkillLibrary.skills(hidden).capitalizedFirst) more are in the library and not listed here." }
    static func noMatch(_ query: String) -> String { "No skill matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”." }
    static func switched(_ name: String, on: Bool) -> String { "\(name) is \(on ? "on" : "off")." }
    static func synced(_ line: String) -> String { line.isEmpty ? "The agent programs are up to date." : "The agent programs are up to date: \(line)." }
    /// The switch changed, the sync did not happen: said with the reason, beside Retry.
    static func notSynced(_ what: String, reason: String) -> String { "\(what) in the library, but the agent programs have not been updated: \(reason)" }
    static func changedInLibrary(_ names: [String], on: Bool) -> String { "\(HerdrSkillLibrary.list(names)) \(names.count == 1 ? "was" : "were") turned \(on ? "on" : "off")" }
    static func sharedInLibrary(_ agent: String) -> String { "\(agent) was added" }
    static func shared(_ agent: String) -> String { "The library is now shared with \(agent)." }
    static func shareTitle(_ agent: String) -> String { "Share these skills with \(agent)?" }
    static func shareConsequence(_ agent: String, server: String, count: Int) -> String {
        "Every session of \(agent) on \(server) will get the \(HerdrSkillLibrary.skills(count)) that are on, including the sessions you start yourself outside \(AppConstants.name). This cannot be cleanly undone from the app."
    }
    static let nothingToShare = "skillshare finds no other agent program on this server to share with. A program is offered once its own folder exists there."

    /// A refusal's own sentence; a server without the routes says it is older.
    static func reason(_ error: Error) -> String {
        if case .http(404, let message)? = error as? HerdrClient.Failure, message.hasPrefix("The Herdr workspace answered HTTP") { return olderWorkspace }
        return error.localizedDescription
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
