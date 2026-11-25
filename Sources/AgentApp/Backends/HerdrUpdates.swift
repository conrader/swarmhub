import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a workspace server says it is: `bridge` in `/api/workspace` (`HerdrWorkspace/src/update.rs`). A server from
/// before it said so sends none of it.
struct HerdrBridgeInfo: Decodable, Sendable, Equatable {
    let version: String
    /// The level of the API the server serves, and the oldest app level it still serves.
    let api: Int
    var apiMin: Int? = nil
    var target: String? = nil
    /// The server can replace itself with a newer release when asked.
    var updates: Bool? = nil
}

/// Whether this app and a workspace server fit, by number. The server counts the level of its API up whenever an
/// app would have to know that something changed; the app is written for one level and says which server levels it
/// still works with. Nothing here is guessed from a route that is or is not there.
enum HerdrCompatibility {
    /// The level this app is written for (`API` in the server). Level 2 added the skill library (`HerdrLibraryGate`);
    /// on a level-1 server the app keeps the list of switches it had.
    /// Level 3 adds scoped Codex steering, detached activity and routine transfers.
    static let level = 3
    /// The oldest server level this app still works with.
    static let oldestServer = 1
    /// What this app says it is with every request (`X-SwarmHub-App`, `X-SwarmHub-Api`).
    static let appHeader = "X-SwarmHub-App", levelHeader = "X-SwarmHub-Api"

    enum Verdict: Equatable, Sendable {
        /// The server serves this app's level.
        case fits
        /// The server serves a newer level too, and still this app's: everything works, and a newer app may do more.
        case serverNewer
        /// The server is older than this app is written for, but one it still works with: what is newer in the app
        /// stays off on this server until it is updated.
        case serverOlder
        /// The server is older than this app works with.
        case serverTooOld
        /// The server does not say what it is: it is from before workspace servers had versions.
        case serverUnversioned
        /// The server no longer serves this app's level: the app is the one to update.
        case appTooOld

        /// The server is the side to update.
        var serverBehind: Bool { self == .serverOlder || self == .serverTooOld || self == .serverUnversioned }
    }

    static func verdict(for bridge: HerdrBridgeInfo?, level: Int = level, oldestServer: Int = oldestServer) -> Verdict {
        guard let bridge else { return .serverUnversioned }
        if (bridge.apiMin ?? bridge.api) > level { return .appTooOld }
        if bridge.api < oldestServer { return .serverTooOld }
        if bridge.api < level { return .serverOlder }
        return bridge.api > level ? .serverNewer : .fits
    }

    /// "0.7.0 (34)" for the header: the version and build of the running app, or "development".
    static func appIdentity(version: String?, build: String?) -> String {
        guard let version, !version.isEmpty else { return "development" }
        return version + (build.map { " (\($0))" } ?? "")
    }
}

/// Why an update request ended without an update, with the server's own word for it (`kind`).
struct HerdrUpdateFailure: LocalizedError, Equatable, Sendable {
    /// `unsupported` (the server has no update routes), `feed_unreachable`, `signature`, `digest`, `no_build`,
    /// `not_writable`, `does_not_run`, `busy`, `changed`, `no_previous`, `journal_changed`, `hc_failed`, or `failed`.
    let kind: String
    let message: String
    var errorDescription: String? { message }

    /// The server could not get the release itself, so the app may hand it over.
    var appCanDeliver: Bool { kind == "feed_unreachable" }
}

extension HerdrClient {
    /// `GET /api/update`: what the server is, whether it can replace its own program, and how its last update ended.
    struct UpdateStatus: Decodable, Sendable, Equatable {
        struct Last: Decodable, Sendable, Equatable { let state: String; let from: String; let to: String; var error: String? = nil }
        let bridge: HerdrBridgeInfo
        var canUpdate: Bool? = nil
        var previous: Bool? = nil
        var last: Last? = nil
    }

    /// `POST /api/update/check`: the newest signed release the server found.
    struct UpdateCheck: Decodable, Sendable, Equatable {
        struct Latest: Decodable, Sendable, Equatable {
            let version: String; let api: Int
            var apiMin: Int? = nil, released: String? = nil, notes: String? = nil, installable: Bool? = nil
        }
        let current: String; let available: Bool; let latest: Latest
    }

    /// The answer to an update or a way back: `restarting` (the server is about to become `to`) or `current`.
    struct UpdateStarted: Decodable, Sendable, Equatable {
        let state: String
        var from: String? = nil, to: String? = nil, version: String? = nil
        var restarting: Bool { state == "restarting" }
    }

    /// What Herdr's own updater said (`hc update --json`, `hc machine update NAME --json`), as far as the app reads it.
    struct CoreUpdate: Decodable, Sendable, Equatable {
        struct Result: Decodable, Sendable, Equatable { var updated: Bool? = nil, restarted: Bool? = nil, was: String? = nil, now: String? = nil }
        let ok: Bool
        var result: Result? = nil

        /// One plain sentence: "Herdr Core is now 0.1.22." or "Herdr Core 0.1.21 is the newest."
        func line(subject: String = "Herdr Core") -> String {
            let now = result?.now, was = result?.was
            if let now, let was, was != now { return "\(subject) is now \(now) (it was \(was))." }
            if result?.updated == true || result?.restarted == true { return "\(subject) was updated\(now.map { " to \($0)" } ?? "")." }
            return "\(subject)\(now.map { " \($0)" } ?? "") is the newest."
        }
    }

    func updateStatus() async throws -> UpdateStatus { try await updateCall("/api/update", method: "GET") }
    func checkUpdate() async throws -> UpdateCheck { try await updateCall("/api/update/check", timeout: 90) }
    /// The server downloads the release itself, checks its signature, tries it and restarts into it. `version` is the
    /// one the person was shown; the server installs no other.
    func applyUpdate(version: String) async throws -> UpdateStarted { try await updateCall("/api/update/apply", body: ["version": version], timeout: 1_200) }
    func rollbackUpdate() async throws -> UpdateStarted { try await updateCall("/api/update/rollback", timeout: 60) }
    /// Herdr's own update of Core on the server (`hc update`). Core restarts; its terminals keep running.
    func updateCore() async throws -> CoreUpdate { try await updateCall("/api/update/core", timeout: 660) }
    /// Herdr's own update of its helper on a project server (`hc machine update NAME`).
    func updateMachine(_ name: String) async throws -> CoreUpdate { try await updateCall("/api/update/machine", body: ["name": name], timeout: 660) }

    /// The same update handed over by the app, for a server that cannot reach the releases: the signed manifest, its
    /// signature and the program. The server checks all three itself, exactly as when it downloads them.
    func uploadUpdate(manifest: Data, signature: String, program: Data) async throws -> UpdateStarted {
        let boundary = "swarmhub-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, _ data: Data, file: Bool = false) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\(file ? "; filename=\"\(name)\"" : "")\r\n".utf8))
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8)); body.append(data); body.append(Data("\r\n".utf8))
        }
        part("manifest", manifest, file: true); part("signature", Data(signature.utf8)); part("program", program, file: true)
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = try request("/api/update/upload", method: "POST", body: nil, timeout: 1_800)
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return try Self.updateAnswer(try await raw(request))
    }

    private struct UpdateRefusal: Decodable { let error: String; var kind: String? = nil }

    private func updateCall<T: Decodable>(_ path: String, method: String = "POST", body: [String: Any] = [:], timeout: TimeInterval = Self.requestSeconds) async throws -> T {
        let data = method == "POST" ? try JSONSerialization.data(withJSONObject: body) : nil
        return try Self.updateAnswer(try await raw(try request(path, method: method, body: data, timeout: timeout)))
    }

    /// An update route's answer, or its refusal with the server's word for why. A server without the routes (404, or
    /// 405 from one that knows the path only by another method) is `unsupported`.
    static func updateAnswer<T: Decodable>(_ answer: (data: Data, status: Int)) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        if (200..<300).contains(answer.status) { return try decoder.decode(T.self, from: answer.data) }
        if answer.status == 401 { throw Failure.unauthorized }
        if answer.status == 403 { throw Failure.refusedHost }
        if answer.status == 404 || answer.status == 405 {
            throw HerdrUpdateFailure(kind: "unsupported", message: "This server’s workspace is from before it could update itself.")
        }
        let refusal = try? decoder.decode(UpdateRefusal.self, from: answer.data)
        throw HerdrUpdateFailure(kind: refusal?.kind ?? "failed", message: refusal?.error ?? "The Herdr workspace answered HTTP \(answer.status).")
    }
}

/// Where one server's workspace stands, and how an update of it is going. A value that only `take` moves, so every
/// step can be checked without a server; `SoftwareUpdateModel` feeds it what the server answers.
struct HerdrServerUpdate: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Nothing has been asked yet.
        case unknown
        case checking
        /// The server did not answer, with why in one sentence.
        case unreachable(String)
        case upToDate
        /// A newer signed release is published and this server can install it.
        case available(version: String, notes: String)
        /// The workspace is behind, and the app cannot update it: it is from before updates, it is installed where it
        /// cannot write, or the release has no program for its kind of machine. The sentence says which.
        case manual(String)
        /// The server is downloading, checking and trying the release.
        case installing(version: String)
        /// The app is downloading the release to hand it over, because the server could not get it itself.
        case delivering(version: String)
        /// The server has taken the new program and is starting it.
        case restarting(from: String, to: String)
        case updated(to: String)
        /// The new version did not start, and the server is back on the one it had.
        case rolledBack(to: String, reason: String)
        case failed(String)
    }

    enum Event: Equatable, Sendable {
        case checkBegan
        /// The server's `/api/workspace` (`bridge` nil: it says nothing about itself) and Core's version.
        case answered(bridge: HerdrBridgeInfo?, core: String?)
        case notReached(String)
        case checked(HerdrClient.UpdateCheck, canUpdate: Bool)
        case checkFailed(HerdrUpdateFailure)
        case installBegan(version: String)
        case deliveryBegan(version: String)
        /// The server answered the request to update.
        case accepted(HerdrClient.UpdateStarted)
        /// The server answered the request to go back to the version its last update replaced.
        case backAccepted(HerdrClient.UpdateStarted)
        case refused(HerdrUpdateFailure)
        /// While restarting: what the server now says it is, and how it says its last update ended.
        case cameBack(version: String, last: HerdrClient.UpdateStatus.Last?)
        /// While restarting: it has not answered for as long as the app waits.
        case stayedAway
    }

    private(set) var phase = Phase.unknown
    private(set) var bridge: HerdrBridgeInfo?
    private(set) var coreVersion: String?
    /// Set once the server has answered at all, so "no version" means an old server and not a silent one.
    private(set) var reached = false
    /// The restart under way, or just finished, is the way back to the previous version.
    private(set) var goingBack = false
    /// What Herdr's own updater last said for this server, shown under it until the next check.
    var coreNote: String?

    var verdict: HerdrCompatibility.Verdict? { reached ? HerdrCompatibility.verdict(for: bridge) : nil }
    var isBusy: Bool {
        switch phase { case .checking, .installing, .delivering, .restarting: true; default: false }
    }
    /// The version an Update button installs now; nil when there is nothing the app can install.
    var installable: String? { if case .available(let version, _) = phase { version } else { nil } }
    /// Something is behind here: an update is ready, or one is needed that the app cannot do.
    var isBehind: Bool {
        switch phase {
        case .available, .manual, .rolledBack: true
        default: false
        }
    }

    static let manualOld = "This server’s workspace is from before it could update itself. Install the new one there once by hand; after that, updates are one click."

    mutating func take(_ event: Event) {
        switch event {
        case .checkBegan:
            if !isBusy { phase = .checking }
        case .answered(let bridge, let core):
            reached = true; self.bridge = bridge; coreVersion = core
            if bridge == nil, !isRestarting { phase = .manual(Self.manualOld) }
        case .notReached(let why):
            if !isRestarting { phase = .unreachable(why) }
        case .checked(let check, let canUpdate):
            guard !isRestarting else { return }
            if !check.available { phase = .upToDate }
            else if check.latest.installable == false { phase = .manual("Workspace \(check.latest.version) is out, but it has no program for this kind of machine\(bridge?.target.map { " (\($0))" } ?? "").") }
            else if !canUpdate { phase = .manual("Workspace \(check.latest.version) is out, but the workspace is installed where it cannot replace itself. Update it the way it was installed on the server.") }
            else { phase = .available(version: check.latest.version, notes: check.latest.notes ?? "") }
        case .checkFailed(let failure):
            guard !isRestarting else { return }
            phase = failure.kind == "unsupported" ? .manual(Self.manualOld) : .failed(failure.message)
        case .installBegan(let version): phase = .installing(version: version)
        case .deliveryBegan(let version): phase = .delivering(version: version)
        case .accepted(let started), .backAccepted(let started):
            if case .backAccepted = event { goingBack = true } else { goingBack = false }
            if started.restarting, let to = started.to { phase = .restarting(from: started.from ?? bridge?.version ?? "", to: to) }
            else { phase = .upToDate }
        case .refused(let failure): phase = .failed(failure.message)
        case .cameBack(let version, let last):
            guard case .restarting(let from, let to) = phase else { return }
            if version == to { phase = .updated(to: to); return }
            // Back on the old version: finished only when the server says the update was undone. Until then the old
            // program may still be about to hand over.
            if version == from, let last, last.to == to, last.state == "rolled_back" || last.state == "failed" {
                phase = .rolledBack(to: to, reason: last.error ?? "The new version did not start.")
            }
        case .stayedAway:
            if case .restarting(_, let to) = phase {
                phase = .failed("The server has not answered since it began to restart into \(to). If it stays away, start the workspace on the server again; the previous version is kept beside it as swarmhub-herdr.previous.")
            }
        }
    }

    private var isRestarting: Bool { if case .restarting = phase { true } else { false } }

    /// One or two plain sentences for what shows under the server's name.
    var line: String {
        switch phase {
        case .unknown: return ""
        case .checking: return "Checking…"
        case .unreachable(let why): return why
        case .upToDate: return verdict == .appTooOld ? "This server is newer than this version of \(AppConstants.name) works with. Update \(AppConstants.name)." : "Up to date."
        case .available(let version, let notes): return "Workspace \(version) is available." + (notes.isEmpty ? "" : " \(notes)")
        case .manual(let why): return why
        case .installing(let version): return "Downloading and checking workspace \(version)…"
        case .delivering(let version): return "The server cannot reach the releases, so this Mac is fetching workspace \(version) for it…"
        case .restarting(_, let to): return goingBack ? "Going back to workspace \(to). Your agents keep running." : "Restarting into workspace \(to). Your agents keep running."
        case .updated(let to): return goingBack ? "Back on workspace \(to). Your agents kept running." : "Updated to workspace \(to). Your agents kept running."
        case .rolledBack(let to, let reason): return "Workspace \(to) did not start, so the server is back on the version it had. Nothing was lost. (\(reason))"
        case .failed(let why): return why
        }
    }
}

/// The answer to "is everything up to date?" across the app and its servers, in one headline and one count.
struct SoftwareUpdateSummary: Equatable, Sendable {
    /// The app's own state as the summary needs it.
    enum App: Equatable, Sendable { case upToDate, available(String), checking, failed, unknown }

    var app: App
    var servers: [HerdrServerUpdate]

    /// What one press of the main button would install: the servers with a release ready, and the app.
    var installableServers: Int { servers.filter { $0.installable != nil }.count }
    var appUpdate: String? { if case .available(let version) = app { version } else { nil } }
    var updates: Int { installableServers + (appUpdate == nil ? 0 : 1) }
    /// Behind in a way no button here fixes.
    var needsHand: Int { servers.filter { if case .manual = $0.phase { true } else { false } }.count }
    var isChecking: Bool { app == .checking || servers.contains { $0.phase == .checking } }
    var isWorking: Bool { servers.contains { $0.isBusy && $0.phase != .checking } }
    var unreachable: Int { servers.filter { if case .unreachable = $0.phase { true } else { false } }.count }

    var headline: String {
        if isWorking { return "Updating…" }
        if updates == 1 { return "An update is available" }
        if updates > 1 { return "\(updates) updates are available" }
        if needsHand > 0 { return needsHand == 1 ? "One server needs an update by hand" : "\(needsHand) servers need an update by hand" }
        if isChecking { return "Checking for updates…" }
        if app == .failed || unreachable > 0 || servers.contains(where: {
            if case .failed = $0.phase { return true }
            if case .rolledBack = $0.phase { return true }
            return false
        }) { return "Could not check for updates" }
        if app == .upToDate, servers.allSatisfy({
            if case .upToDate = $0.phase { return true }
            if case .updated = $0.phase { return true }
            return false
        }) { return "Everything is up to date" }
        return "Software Update"
    }

    /// The main button's title; nil when there is nothing to install.
    var action: String? {
        guard updates > 0, !isWorking else { return nil }
        return updates == 1 ? "Update Now" : "Update All"
    }
}
