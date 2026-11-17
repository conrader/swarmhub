import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The library routes of a workspace at API level 2 (`HerdrSkillLibrary.swift` has the answers). Every route takes
/// an optional `project`: the full path of a folder on the server that holds a skillshare project. With it the route
/// works on that project's library, without it on the one all bots share. The repository and the server itself are
/// about the shared library only. A refusal is thrown with the workspace's own sentence (`HerdrLibraryRefusal`).
extension HerdrClient {
    /// The server stops a program after 20 seconds for a read, 60 for a change, 120 for a sync, a check, a pull or a
    /// push, 180 for an install or an update and 300 for updating skillshare, and says so. The client waits a little
    /// longer each time, so that the server's own sentence arrives instead of a silent timeout here.
    static let libraryReadSeconds: TimeInterval = 35, libraryChangeSeconds: TimeInterval = 80, librarySyncSeconds: TimeInterval = 140
    static let libraryInstallSeconds: TimeInterval = 200, libraryUpgradeSeconds: TimeInterval = 320

    /// `?a=1&b=2` from the values that are there, each percent-encoded.
    static func libraryQuery(_ items: [(String, String?)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let parts = items.compactMap { name, value in value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0)" } }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }

    private func libraryRoute<T: Decodable>(_ path: String, body: [String: Any]? = nil, project: String? = nil, timeout: TimeInterval) async throws -> T {
        var sent = body
        if let project, !project.isEmpty, sent != nil { sent?["project"] = project }
        let (data, status) = try await raw(request(path, method: sent == nil ? "GET" : "POST", body: try sent.map { try JSONSerialization.data(withJSONObject: $0) }, timeout: timeout))
        if status == 401 { throw Failure.unauthorized }
        if status == 403 { throw Failure.refusedHost }
        guard (200..<300).contains(status) else { throw HerdrLibraryRefusal.of(status: status, body: data) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    func library(project: String? = nil) async throws -> HerdrLibrary {
        try await libraryRoute("/api/skillshare/library" + Self.libraryQuery([("project", project)]), timeout: Self.libraryReadSeconds)
    }

    /// Asks every installed skill's and agent's origin whether there is a newer version. It can take a minute.
    func checkLibrary(project: String? = nil) async throws -> HerdrLibraryAnswer {
        try await libraryRoute("/api/skillshare/check", body: [:], project: project, timeout: Self.librarySyncSeconds)
    }

    /// Brings skills, agents, MCP servers and hooks to every Target, and plugins when one waits.
    func syncLibrary(project: String? = nil) async throws -> HerdrLibrarySynced {
        try await libraryRoute("/api/skillshare/sync", body: ["all": true], project: project, timeout: Self.librarySyncSeconds)
    }

    /// Turns a skill, an agent or a hook on or off in the library. The agent programs see it after a sync.
    func setLibraryItem(_ id: String, enabled: Bool, project: String? = nil) async throws -> HerdrLibraryAnswer {
        try await libraryRoute("/api/skillshare/\(enabled ? "enable" : "disable")", body: ["id": id], project: project, timeout: Self.libraryChangeSeconds)
    }

    /// What there is to read about one thing; `file` names another of a skill's files than its `SKILL.md`.
    func libraryPreview(_ id: String, file: String? = nil, project: String? = nil) async throws -> HerdrLibraryPreview {
        try await libraryRoute("/api/skillshare/preview" + Self.libraryQuery([("id", id), ("file", file), ("project", project)]), timeout: Self.libraryReadSeconds)
    }

    /// What a sync would change for this thing; with `edits` what was edited in this one skill since it was installed.
    func libraryDiff(_ id: String, edits: Bool = false, project: String? = nil) async throws -> HerdrLibraryDiff {
        try await libraryRoute("/api/skillshare/diff" + Self.libraryQuery([("id", id), ("what", edits ? "edits" : nil), ("project", project)]), timeout: Self.libraryReadSeconds)
    }

    /// Downloads a repository on the server, lists its skills and audits each. Nothing is installed.
    func inspectInstall(_ source: String, project: String? = nil) async throws -> HerdrInstallInspection {
        try await libraryRoute("/api/skillshare/install/inspect", body: ["source": source], project: project, timeout: Self.libraryInstallSeconds)
    }

    /// Installs the named skills of an inspected download. `replace` lets it replace skills the library already has;
    /// `force` installs skills the audit blocked, and is sent only after the person said so.
    func install(ticket: String, skills: [String], replace: Bool, force: Bool, project: String? = nil) async throws -> HerdrLibraryAnswer {
        var body: [String: Any] = ["ticket": ticket, "skills": skills]
        if replace { body["replace"] = true }
        if force { body["force"] = true }
        return try await libraryRoute("/api/skillshare/install", body: body, project: project, timeout: Self.libraryInstallSeconds)
    }

    /// Removes an inspected download without installing.
    func cancelInstall(ticket: String, project: String? = nil) async throws {
        struct Done: Decodable {}
        let _: Done = try await libraryRoute("/api/skillshare/install/cancel", body: ["ticket": ticket], project: project, timeout: Self.libraryChangeSeconds)
    }

    /// Updates one skill or agent, or with `id` nil every one that has an update.
    func updateLibrary(_ id: String?, project: String? = nil) async throws -> HerdrLibraryAnswer {
        try await libraryRoute("/api/skillshare/update", body: id.map { ["id": $0] } ?? ["all": true], project: project, timeout: Self.libraryInstallSeconds)
    }

    /// Moves a skill, an agent or a hook to skillshare's trash. Sent only after the person confirmed.
    func uninstall(_ id: String, project: String? = nil) async throws -> HerdrLibraryAnswer {
        try await libraryRoute("/api/skillshare/uninstall", body: ["id": id, "confirm": true], project: project, timeout: Self.libraryChangeSeconds)
    }

    // MARK: The library's Git repository (the shared library only)

    /// With `fetch` the workspace first asks the remote what is new.
    func librarySource(fetch: Bool = false) async throws -> HerdrLibrarySource {
        try await libraryRoute("/api/skillshare/source" + Self.libraryQuery([("fetch", fetch ? "true" : nil)]), timeout: fetch ? Self.librarySyncSeconds : Self.libraryReadSeconds)
    }

    func pullSource() async throws -> HerdrSourceAnswer { try await libraryRoute("/api/skillshare/source/pull", body: [:], timeout: Self.librarySyncSeconds) }

    private static func sourceBody(_ message: String) -> [String: Any] {
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? ["confirm": true] : ["confirm": true, "message": note]
    }
    /// Commits what is uncommitted and pushes. Sent only after the person confirmed.
    func pushSource(message: String) async throws -> HerdrSourceAnswer { try await libraryRoute("/api/skillshare/source/push", body: Self.sourceBody(message), timeout: Self.librarySyncSeconds) }
    /// Pull, then push, then sync the Targets. Sent only after the person confirmed.
    func syncSource(message: String) async throws -> HerdrSourceAnswer { try await libraryRoute("/api/skillshare/source/sync", body: Self.sourceBody(message), timeout: Self.librarySyncSeconds) }

    /// Merges with `mine` or `theirs` for every file of a conflict, and pushes when `push`. Sent only after the person confirmed.
    func resolveSource(choices: [String: String], push: Bool) async throws -> HerdrSourceAnswer {
        try await libraryRoute("/api/skillshare/source/resolve", body: ["confirm": true, "push": push, "choices": choices], timeout: Self.librarySyncSeconds)
    }

    // MARK: The server itself

    /// skillshare on this server; with `check` the workspace also looks for skillshare's newest release.
    func skillshareMachine(check: Bool = false) async throws -> HerdrLibraryMachine {
        try await libraryRoute("/api/skillshare/machine" + Self.libraryQuery([("check", check ? "true" : nil)]), timeout: Self.libraryReadSeconds)
    }

    /// Replaces the skillshare program on the server with the newest release. Sent only after the person confirmed.
    func upgradeSkillshare() async throws -> HerdrSkillshareUpgraded {
        try await libraryRoute("/api/skillshare/upgrade", body: ["confirm": true], timeout: Self.libraryUpgradeSeconds)
    }

    /// Which of these folders on the server hold a skillshare project, and whether the folder its bots work in does.
    func skillshareProjects(folders: [String]) async throws -> HerdrSkillshareProjects {
        try await libraryRoute("/api/skillshare/projects" + Self.libraryQuery(folders.map { ("folder", Optional($0)) }), timeout: Self.libraryReadSeconds)
    }
}
