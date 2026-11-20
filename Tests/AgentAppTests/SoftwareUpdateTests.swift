import CryptoKit
import Foundation
import Testing
@testable import AgentApp

// Software Update: whether the app and a server fit by number, how a server's update moves from state to state,
// the one headline over everything, and what the app accepts as a workspace release.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func bridge(_ version: String = "0.2.0", api: Int = HerdrCompatibility.level, apiMin: Int? = 1, target: String? = "x86_64-linux") -> HerdrBridgeInfo {
    HerdrBridgeInfo(version: version, api: api, apiMin: apiMin, target: target, updates: true)
}
private func check(_ latest: String, current: String = "0.2.0", available: Bool = true, installable: Bool? = true, notes: String? = nil) -> HerdrClient.UpdateCheck {
    HerdrClient.UpdateCheck(current: current, available: available, latest: .init(version: latest, api: 1, notes: notes, installable: installable))
}
private func moved(_ events: [HerdrServerUpdate.Event]) -> HerdrServerUpdate { var state = HerdrServerUpdate(); events.forEach { state.take($0) }; return state }
private let answered = HerdrServerUpdate.Event.answered(bridge: bridge(), core: "0.1.21")
private let restarting: [HerdrServerUpdate.Event] = [answered, .checked(check("0.2.1"), canUpdate: true), .installBegan(version: "0.2.1"),
                                                    .accepted(.init(state: "restarting", from: "0.2.0", to: "0.2.1"))]

@Test func theAppAndAServerFitByNumber() {
    func verdict(_ api: Int, min: Int? = nil, level: Int, oldest: Int) -> HerdrCompatibility.Verdict {
        HerdrCompatibility.verdict(for: bridge(api: api, apiMin: min), level: level, oldestServer: oldest)
    }
    #expect(HerdrCompatibility.verdict(for: nil) == .serverUnversioned, "a server that says nothing about itself is from before versions")
    #expect(HerdrCompatibility.verdict(for: bridge()) == .fits, "today's server and today's app")
    #expect(HerdrCompatibility.verdict(for: bridge(api: 1)) == .serverOlder && HerdrCompatibility.oldestServer == 1, "the first published server still works with this app; only what came later stays off")
    #expect(verdict(3, min: 1, level: 3, oldest: 2) == .fits)
    #expect(verdict(4, min: 2, level: 3, oldest: 2) == .serverNewer, "a newer server that still serves this app")
    #expect(verdict(2, min: 1, level: 3, oldest: 2) == .serverOlder, "older than the app is written for, but one it works with")
    #expect(verdict(1, min: 1, level: 3, oldest: 2) == .serverTooOld)
    #expect(verdict(5, min: 4, level: 3, oldest: 2) == .appTooOld, "the server dropped this app's level")
    #expect(verdict(5, min: nil, level: 3, oldest: 2) == .appTooOld, "a server that names no oldest level serves only its own")
    #expect([.serverOlder, .serverTooOld, .serverUnversioned].allSatisfy(\HerdrCompatibility.Verdict.serverBehind)
            && ![.fits, .serverNewer, .appTooOld].contains(where: \HerdrCompatibility.Verdict.serverBehind))
    #expect(HerdrCompatibility.oldestServer <= HerdrCompatibility.level)
    #expect(HerdrCompatibility.appIdentity(version: "0.7.0", build: "34") == "0.7.0 (34)" && HerdrCompatibility.appIdentity(version: nil, build: "34") == "development")
}

/// The numbers the app and the server compare, and the key both trust, are the same in the two codebases.
@Test func theAppAndTheServerSourceAgreeOnTheLevelAndTheReleaseKey() throws {
    let source = try String(contentsOf: repoRoot.appending(path: "HerdrWorkspace/src/update.rs"), encoding: .utf8)
    func constant(_ name: String) throws -> Int {
        let match = try #require(source.firstMatch(of: try Regex("pub\\(crate\\) const \(name): u32 = ([0-9]+);")))
        return try #require(Int(String(match.output[1].substring ?? "")))
    }
    let api = try constant("API"), apiMin = try constant("API_MIN")
    #expect(HerdrCompatibility.verdict(for: bridge(api: api, apiMin: apiMin)) == .fits, "this app fits the server built from the same tree")
    let info = try #require(NSDictionary(contentsOf: repoRoot.appending(path: "Resources/Info.plist")))
    let key = try #require(info["SUPublicEDKey"] as? String)
    #expect(Data(base64Encoded: key)?.count == 32 && source.contains("None => \"\(key)\""), "the server trusts the key the app's own updates are signed with")
    #expect(source.contains("\"\(WorkspaceRelease.feed)\"") && source.contains("\"\(WorkspaceRelease.assets)\"") && source.contains("\"\(WorkspaceRelease.manifestName)\""))
}

@Test func aServerSaysWhatItIsAndTheAppSaysWhatItIs() async throws {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let old = try decoder.decode(HerdrClient.Workspace.self, from: Data(#"{"core":"c","version":"0.1.21","agents":[],"templates":[]}"#.utf8))
    #expect(old.bridge == nil && old.version == "0.1.21")
    let new = try decoder.decode(HerdrClient.Workspace.self, from: Data(#"{"core":"c","version":"0.1.21","agents":[],"templates":[],"bridge":{"version":"0.2.0","api":1,"api_min":1,"target":"x86_64-linux","updates":true,"later":"ignored"}}"#.utf8))
    #expect(new.bridge == bridge(api: 1))

    let client = HerdrClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "t")
    let request = try client.request("/api/workspace", method: "GET", body: nil)
    #expect(request.value(forHTTPHeaderField: HerdrCompatibility.levelHeader) == String(HerdrCompatibility.level))
    #expect(request.value(forHTTPHeaderField: HerdrCompatibility.appHeader) == HerdrClient.appIdentity && !HerdrClient.appIdentity.isEmpty)
}

@Test func anUpdateRoutesRefusalKeepsTheServersWordForIt() throws {
    let started: HerdrClient.UpdateStarted = try HerdrClient.updateAnswer((Data(#"{"state":"restarting","from":"0.2.0","to":"0.2.1"}"#.utf8), 200))
    #expect(started.restarting && started.to == "0.2.1")
    let current: HerdrClient.UpdateStarted = try HerdrClient.updateAnswer((Data(#"{"state":"current","version":"0.2.1"}"#.utf8), 200))
    #expect(!current.restarting)
    func failure(_ status: Int, _ body: String) -> HerdrUpdateFailure? {
        do { let _: HerdrClient.UpdateStarted = try HerdrClient.updateAnswer((Data(body.utf8), status)); return nil } catch { return error as? HerdrUpdateFailure }
    }
    #expect(failure(404, "")?.kind == "unsupported" && failure(405, "")?.kind == "unsupported", "a server without the routes")
    let offline = try #require(failure(502, #"{"error":"This server could not download the new program from the SwarmHub releases.","kind":"feed_unreachable"}"#))
    #expect(offline.appCanDeliver && offline.message.hasPrefix("This server could not download"))
    #expect(failure(502, #"{"error":"Not signed.","kind":"signature"}"#)?.appCanDeliver == false)
    #expect(failure(500, "<html>")?.kind == "failed")
    #expect(throws: HerdrClient.Failure.unauthorized) { let _: HerdrClient.UpdateStarted = try HerdrClient.updateAnswer((Data(), 401)) }
    let status: HerdrClient.UpdateStatus = try HerdrClient.updateAnswer((Data(#"{"bridge":{"version":"0.2.0","api":1,"api_min":1},"pid":7,"can_update":true,"previous":true,"last":{"state":"rolled_back","from":"0.2.0","to":"0.2.1","at_ms":1,"error":"x","backup":"/b"},"app":null}"#.utf8), 200))
    #expect(status.canUpdate == true && status.previous == true && status.last == .init(state: "rolled_back", from: "0.2.0", to: "0.2.1", error: "x"))
    let core = HerdrClient.CoreUpdate(ok: true, result: .init(was: "0.1.21", now: "0.1.22"))
    #expect(core.line() == "Herdr Core is now 0.1.22 (it was 0.1.21).")
    #expect(HerdrClient.CoreUpdate(ok: true, result: .init(updated: false, now: "0.1.22")).line(subject: "Herdr on build-box") == "Herdr on build-box 0.1.22 is the newest.")
    #expect(HerdrClient.CoreUpdate(ok: true).line() == "Herdr Core is the newest.")
}

@Test func aServersUpdateMovesFromCheckToTheNewVersion() {
    var state = HerdrServerUpdate()
    #expect(state.phase == .unknown && state.verdict == nil && !state.isBehind && state.line.isEmpty)
    state.take(.checkBegan)
    #expect(state.phase == .checking && state.isBusy)
    state.take(answered)
    #expect(state.verdict == .fits && state.bridge?.version == "0.2.0" && state.coreVersion == "0.1.21")
    state.take(.checked(check("0.2.0", available: false), canUpdate: true))
    #expect(state.phase == .upToDate && !state.isBehind && state.installable == nil && state.line == "Up to date.")

    state.take(.checkBegan); state.take(.checked(check("0.2.1", notes: "Faster starts."), canUpdate: true))
    #expect(state.phase == .available(version: "0.2.1", notes: "Faster starts.") && state.installable == "0.2.1" && state.isBehind)
    #expect(state.line == "Workspace 0.2.1 is available. Faster starts.")
    state.take(.installBegan(version: "0.2.1"))
    #expect(state.isBusy && state.installable == nil)
    state.take(.checkBegan)
    #expect(state.phase == .installing(version: "0.2.1"), "a check does not interrupt an update")
    state.take(.accepted(.init(state: "restarting", from: "0.2.0", to: "0.2.1")))
    #expect(state.phase == .restarting(from: "0.2.0", to: "0.2.1") && state.line.contains("Your agents keep running"))

    // While it restarts nothing else moves it: not a failed request, not a check, not the old version still answering.
    state.take(.notReached("gone")); state.take(.checked(check("0.2.1"), canUpdate: true)); state.take(.checkFailed(.init(kind: "failed", message: "x")))
    state.take(.cameBack(version: "0.2.0", last: nil))
    state.take(.cameBack(version: "0.2.0", last: .init(state: "trial", from: "0.2.0", to: "0.2.1")))
    #expect(state.phase == .restarting(from: "0.2.0", to: "0.2.1"), "the old version may still be about to hand over")
    state.take(.cameBack(version: "0.2.1", last: .init(state: "done", from: "0.2.0", to: "0.2.1")))
    #expect(state.phase == .updated(to: "0.2.1") && !state.isBusy && !state.isBehind && state.line == "Updated to workspace 0.2.1. Your agents kept running.")
    state.take(.cameBack(version: "0.2.0", last: nil))
    #expect(state.phase == .updated(to: "0.2.1"), "a late answer changes nothing once it is settled")
}

@Test func anUpdateThatDoesNotStartEndsBackOnTheOldVersionAndSaysSo() {
    var state = moved(restarting)
    state.take(.cameBack(version: "0.2.0", last: .init(state: "rolled_back", from: "0.1.9", to: "0.2.0")))
    #expect(state.phase == .restarting(from: "0.2.0", to: "0.2.1"), "an older update's ending is not this one's")
    state.take(.cameBack(version: "0.2.0", last: .init(state: "rolled_back", from: "0.2.0", to: "0.2.1", error: "The journal could not be opened.")))
    #expect(state.phase == .rolledBack(to: "0.2.1", reason: "The journal could not be opened.") && state.isBehind && !state.isBusy)
    #expect(state.line.contains("back on the version it had") && state.line.contains("Nothing was lost") && state.line.contains("The journal could not be opened."))

    var silent = moved(restarting)
    silent.take(.stayedAway)
    guard case .failed(let why) = silent.phase else { Issue.record("\(silent.phase)"); return }
    #expect(why.contains("has not answered") && why.contains("swarmhub-herdr.previous"))

    var refused = moved([answered, .checked(check("0.2.1"), canUpdate: true), .installBegan(version: "0.2.1")])
    refused.take(.refused(.init(kind: "does_not_run", message: "The new version does not run on this server (it says it is 0.3.0), so nothing was changed.")))
    #expect(refused.phase == .failed("The new version does not run on this server (it says it is 0.3.0), so nothing was changed.") && !refused.isBusy)

    var already = moved([answered, .checked(check("0.2.1"), canUpdate: true), .installBegan(version: "0.2.1")])
    already.take(.accepted(.init(state: "current", version: "0.2.1")))
    #expect(already.phase == .upToDate)

    var delivered = moved([answered, .checked(check("0.2.1"), canUpdate: true), .installBegan(version: "0.2.1"), .deliveryBegan(version: "0.2.1")])
    #expect(delivered.isBusy && delivered.line.contains("this Mac is fetching workspace 0.2.1"))
    delivered.take(.accepted(.init(state: "restarting", from: "0.2.0", to: "0.2.1")))
    #expect(delivered.phase == .restarting(from: "0.2.0", to: "0.2.1"))
}

@Test func whatTheAppCannotUpdateItSaysPlainly() {
    let old = moved([.checkBegan, .answered(bridge: nil, core: "0.1.21")])
    #expect(old.phase == .manual(HerdrServerUpdate.manualOld) && old.verdict == .serverUnversioned && old.isBehind && old.installable == nil)
    let noRoutes = moved([answered, .checkFailed(.init(kind: "unsupported", message: "x"))])
    #expect(noRoutes.phase == .manual(HerdrServerUpdate.manualOld))
    let readOnly = moved([answered, .checked(check("0.2.1"), canUpdate: false)])
    guard case .manual(let why) = readOnly.phase else { Issue.record("\(readOnly.phase)"); return }
    #expect(why.contains("Workspace 0.2.1 is out") && why.contains("cannot replace itself"))
    let noBuild = moved([answered, .checked(check("0.2.1", installable: false), canUpdate: true)])
    guard case .manual(let which) = noBuild.phase else { Issue.record("\(noBuild.phase)"); return }
    #expect(which.contains("no program for this kind of machine (x86_64-linux)"))
    let away = moved([.checkBegan, .notReached("Nothing answers on this Mac at 127.0.0.1:8787.")])
    #expect(away.phase == .unreachable("Nothing answers on this Mac at 127.0.0.1:8787.") && away.verdict == nil && !away.isBehind)
    let failed = moved([answered, .checkFailed(.init(kind: "signature", message: "The update is not signed with the SwarmHub release key, so it was not installed."))])
    #expect(failed.phase == .failed("The update is not signed with the SwarmHub release key, so it was not installed.") && failed.installable == nil)
    let tooNew = moved([.answered(bridge: bridge(api: 9, apiMin: 8), core: nil), .checked(check("9.0.0", current: "9.0.0", available: false), canUpdate: true)])
    #expect(tooNew.verdict == .appTooOld && tooNew.line == "This server is newer than this version of SwarmHub works with. Update SwarmHub.")
}

@Test func oneHeadlineAnswersWhetherEverythingIsUpToDate() {
    let current = moved([answered, .checked(check("0.2.0", available: false), canUpdate: true)])
    let behind = moved([answered, .checked(check("0.2.1"), canUpdate: true)])
    let old = moved([.answered(bridge: nil, core: nil)])
    let away = moved([.notReached("x")])
    func summary(_ app: SoftwareUpdateSummary.App, _ servers: [HerdrServerUpdate]) -> SoftwareUpdateSummary { SoftwareUpdateSummary(app: app, servers: servers) }

    let fine = summary(.upToDate, [current, current])
    #expect(fine.headline == "Everything is up to date" && fine.action == nil && fine.updates == 0)
    let one = summary(.upToDate, [current, behind])
    #expect(one.headline == "An update is available" && one.action == "Update Now" && one.installableServers == 1 && one.appUpdate == nil)
    let both = summary(.available("0.7.1"), [behind, behind])
    #expect(both.headline == "3 updates are available" && both.action == "Update All" && both.appUpdate == "0.7.1")
    let appOnly = summary(.available("0.7.1"), [])
    #expect(appOnly.headline == "An update is available" && appOnly.action == "Update Now")
    let hand = summary(.upToDate, [old, current])
    #expect(hand.headline == "One server needs an update by hand" && hand.action == nil && hand.needsHand == 1)
    #expect(summary(.upToDate, [old, old]).headline == "2 servers need an update by hand")
    #expect(summary(.upToDate, [old, behind]).headline == "An update is available", "what a button can fix comes first")
    #expect(summary(.upToDate, [moved([.checkBegan]), current]).headline == "Checking for updates…")
    let working = summary(.available("0.7.1"), [moved(restarting), behind])
    #expect(working.headline == "Updating…" && working.action == nil, "no second update is started while one runs")
    #expect(summary(.upToDate, [away, current]).headline == "SwarmHub is up to date" && summary(.unknown, [away]).headline == "Could not check")
    #expect(summary(.unknown, [HerdrServerUpdate()]).headline == "Software Update" && summary(.upToDate, []).headline == "Everything is up to date")
    #expect(SoftwareUpdatePane.detail(fine, servers: ["Mac", "Studio"]) == "SwarmHub and the workspace on your 2 servers." && SoftwareUpdatePane.detail(appOnly, servers: []) == "SwarmHub 0.7.1.")
    #expect(SoftwareUpdatePane.detail(one, servers: ["Mac", "Studio"]) == "The workspace on Studio." && SoftwareUpdatePane.detail(both, servers: ["Mac", "Studio"]) == "SwarmHub 0.7.1 and the workspace on Mac and Studio.")
    #expect(SoftwareUpdatePane.detail(summary(.upToDate, [current]), servers: ["Mac"]) == "SwarmHub and the workspace on your server." && SoftwareUpdatePane.detail(working, servers: ["Mac", "Studio"]).contains("Your agents keep running"))
}

@Test func theAppsOwnLineSaysWhatACheckFound() {
    var line = SoftwareUpdatePane.AppLine(version: "0.7.0 (34)")
    #expect(line.state == .unknown && line.sentence == "Not checked yet.")
    line.lastCheck = .now
    #expect(line.state == .upToDate && line.sentence.hasPrefix("Up to date. Last checked"))
    line.problem = "The feed could not be read."
    #expect(line.sentence == "Could not check: The feed could not be read.")
    line.available = "0.7.1"
    #expect(line.state == .available("0.7.1") && line.sentence.hasPrefix("Version 0.7.1 is available."))
    let development = SoftwareUpdatePane.AppLine(version: "0.7.0", lastCheck: .now, unavailable: "Run the installed application to enable automatic updates.")
    #expect(development.state == .unknown && development.sentence == "Run the installed application to enable automatic updates.")

    #expect(UpdateConfiguration.problem(from: NSError(domain: "SUSparkleErrorDomain", code: 1001)) == nil, "nothing newer is not a problem")
    #expect(UpdateConfiguration.problem(from: NSError(domain: "SUSparkleErrorDomain", code: 4007)) == nil)
    #expect(UpdateConfiguration.problem(from: NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSLocalizedDescriptionKey: "The feed could not be read."])) == "The feed could not be read.")
    #expect(UpdateConfiguration.isAutomated(environment: ["SWARMHUB_DISABLE_UPDATES": "1"]) && UpdateConfiguration.isAutomated(environment: [:], arguments: ["AgentApp", "--ui-smoke"])
            && !UpdateConfiguration.isAutomated(environment: ["AGENTAPP_APPEARANCE": "Dark"]))
}

@MainActor @Test func theSidebarsLineSaysWhatIsWaiting() {
    let notice = UpdateNotice()
    #expect(notice.line == nil)
    notice.serversBehind = 1
    #expect(notice.line == "A server update is available")
    notice.serversBehind = 3
    #expect(notice.line == "3 server updates are available")
    notice.appVersion = "0.7.1"
    #expect(notice.line == "Updates are available")
    notice.serversBehind = 0
    #expect(notice.line == "SwarmHub 0.7.1 is available")
}

// MARK: A workspace release, as the app reads it

private struct SignedRelease {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    var program = Data("the program".utf8)

    func manifest(version: String = "0.2.1", product: String = "swarmhub-herdr", name: String = "swarmhub-herdr-0.2.1-x86_64-linux", base: String? = nil, target: String = "x86_64-linux") -> Data {
        let digest = SHA256.hash(data: program).map { String(format: "%02x", $0) }.joined()
        let object: [String: Any] = ["product": product, "version": version, "api": 1, "api_min": 1, "released": "2026-11-17", "notes": "Faster starts.",
                                     "base": base ?? "\(WorkspaceRelease.assets)v0.7.1/",
                                     "assets": [["target": target, "name": name, "size": program.count, "sha256": digest]]]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func sign(_ data: Data) -> String { try! key.signature(for: data).base64EncodedString() }
}

@Test func theAppAcceptsOnlyAReleaseSignedWithItsKey() throws {
    let signed = SignedRelease(), data = signed.manifest()
    let release = try WorkspaceRelease.verified(manifest: data, signature: signed.sign(data) + "\n", publicKey: signed.publicKey)
    #expect(release.manifest.version == "0.2.1" && release.manifest.apiMin == 1 && release.manifestData == data && !release.signature.hasSuffix("\n"))
    #expect(release.asset(for: "x86_64-linux")?.size == signed.program.count && release.asset(for: "aarch64-linux") == nil)
    #expect(WorkspaceRelease.matches(signed.program, release.manifest.assets[0]) && !WorkspaceRelease.matches(Data("the program!".utf8), release.manifest.assets[0])
            && !WorkspaceRelease.matches(Data("THE PROGRAM".utf8), release.manifest.assets[0]))

    var changed = data; changed[changed.count - 2] ^= 1
    #expect(throws: WorkspaceRelease.Failure.unsigned) { try WorkspaceRelease.verified(manifest: changed, signature: signed.sign(data), publicKey: signed.publicKey) }
    #expect(throws: WorkspaceRelease.Failure.unsigned) { try WorkspaceRelease.verified(manifest: data, signature: SignedRelease().sign(data), publicKey: signed.publicKey) }
    #expect(throws: WorkspaceRelease.Failure.unsigned) { try WorkspaceRelease.verified(manifest: data, signature: "", publicKey: signed.publicKey) }
    #expect(throws: WorkspaceRelease.Failure.unsigned) { try WorkspaceRelease.verified(manifest: data, signature: signed.sign(data), publicKey: "") }
    for odd in [signed.manifest(product: "other"), signed.manifest(version: "0.2"), signed.manifest(version: "0.2.1-beta"), signed.manifest(name: "../x"), signed.manifest(name: "a/b"), signed.manifest(name: ".x")] {
        #expect(throws: WorkspaceRelease.Failure.unreadable) { try WorkspaceRelease.verified(manifest: odd, signature: signed.sign(odd), publicKey: signed.publicKey) }
    }
}

@Test func theProgramComesFromTheReleasesAndNowhereElse() throws {
    let signed = SignedRelease()
    func release(base: String? = nil) throws -> WorkspaceRelease {
        let data = signed.manifest(base: base)
        return try WorkspaceRelease.verified(manifest: data, signature: signed.sign(data), publicKey: signed.publicKey)
    }
    #expect(try release().programURL(for: "x86_64-linux").absoluteString == "\(WorkspaceRelease.assets)v0.7.1/swarmhub-herdr-0.2.1-x86_64-linux")
    #expect(throws: WorkspaceRelease.Failure.noProgram("aarch64-macos")) { try release().programURL(for: "aarch64-macos") }
    for base in ["https://example.com/", "\(WorkspaceRelease.assets)../../other/", "\(WorkspaceRelease.assets)v0.7.1", ""] {
        #expect(throws: WorkspaceRelease.Failure.elsewhere, "\(base)") { try release(base: base).programURL(for: "x86_64-linux") }
    }
    #expect(try release(base: "https://example.com/").programURL(for: "x86_64-linux", mirror: "http://127.0.0.1:9000/feed/").absoluteString == "http://127.0.0.1:9000/feed/swarmhub-herdr-0.2.1-x86_64-linux")
    #expect(WorkspaceRelease.mirror("http://127.0.0.1:9000/feed") == "http://127.0.0.1:9000/feed/" && WorkspaceRelease.mirror("https://mirror.example/x/") == "https://mirror.example/x/")
    for odd in [nil, "", "http://example.com/x", "file:///tmp/x", "https://user@example.com/x", "https://example.com/x?y"] { #expect(WorkspaceRelease.mirror(odd) == nil) }

    // What a server that cannot look itself is told.
    let found = try release().check(current: "0.2.0", target: "x86_64-linux")
    #expect(found.available && found.latest.version == "0.2.1" && found.latest.installable == true && found.latest.notes == "Faster starts.")
    #expect(try !release().check(current: "0.2.1", target: "x86_64-linux").available && !release().check(current: "0.3.0", target: nil).available)
    #expect(try release().check(current: "0.2.0", target: "aarch64-linux").latest.installable == false)
}

// MARK: The model against a server

/// A workspace server as the update routes see it: it says what it is, finds a release, takes it, is away while it
/// restarts and comes back as what `outcome` says.
private final class UpdatingServer: @unchecked Sendable {
    enum Outcome { case updated, rolledBack, away }
    private let lock = NSLock()
    private var version = "0.2.0", last: [String: Any]?, restartingFor = 0, applied: [String] = [], uploads = 0
    var outcome = Outcome.updated
    var feedReachable = true, versioned = true
    private(set) var session = URLSession.shared
    private(set) var host = ""
    var appliedVersions: [String] { lock.withLock { applied } }
    var uploadCount: Int { lock.withLock { uploads } }

    init() {
        let served = MockHTTPProtocol.serve { [weak self] request in self?.answer(request) ?? (503, ["error": "gone"]) }
        host = served.host; session = served.session
    }

    private func answer(_ request: URLRequest) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        if restartingFor > 0, route != "GET /api/workspace" {
            restartingFor -= 1
            if restartingFor == 0, outcome != .away {
                if outcome == .updated { last?["state"] = "done"; version = "0.2.1" } else { last?["state"] = "rolled_back"; last?["error"] = "It never starts." }
            } else { return (503, ["error": "restarting"]) }
        }
        let bridge: [String: Any] = ["version": version, "api": 1, "api_min": 1, "target": "x86_64-linux", "updates": true]
        switch route {
        case "GET /api/workspace":
            var workspace: [String: Any] = ["core": "c", "version": "0.1.21", "agents": [Any](), "templates": [Any]()]
            if versioned { workspace["bridge"] = bridge }
            return (200, workspace)
        case "GET /api/update":
            guard versioned else { return (404, ["error": "no route"]) }
            return (200, ["bridge": bridge, "can_update": true, "previous": last?["state"] as? String == "done", "last": last.map { $0 as Any } ?? NSNull()])
        case "GET /api/machines": return (200, ["machines": [["name": "build-box", "state": "needs_update"], ["name": "docs-box", "state": "connected"]]])
        case "POST /api/update/check":
            guard feedReachable else { return (502, ["error": "This server could not download the update's description from the SwarmHub releases.", "kind": "feed_unreachable"]) }
            return (200, ["current": version, "available": version == "0.2.0", "latest": ["version": "0.2.1", "api": 1, "api_min": 1, "notes": "Faster starts.", "installable": true]])
        case "POST /api/update/apply":
            let wanted = (request.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["version"] as? String ?? ""
            applied.append(wanted)
            last = ["state": "trial", "from": "0.2.0", "to": "0.2.1"]; restartingFor = outcome == .away ? .max : 3
            return (200, ["state": "restarting", "from": "0.2.0", "to": "0.2.1"])
        case "POST /api/update/rollback":
            version = "0.2.0"; last = ["state": "rolled_back", "from": "0.2.0", "to": "0.2.1", "error": "Rolled back on request."]
            return (200, ["state": "restarting", "from": "0.2.1", "to": "0.2.0"])
        case "POST /api/update/core": return (200, ["ok": true, "result": ["was": "0.1.21", "now": "0.1.22", "restarted": true]])
        case "POST /api/update/machine": return (200, ["ok": true, "result": ["updated": true, "now": "0.1.22"]])
        default: return (404, ["error": "no route"])
        }
    }
}

@MainActor private func updateStore(_ server: UpdatingServer) -> (store: AppStore, server: HerdrServer, model: SoftwareUpdateModel) {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let saved = HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: "http://\(server.host):8787")
    store.saveHerdrServer(saved, token: "t")
    let session = server.session
    store.herdrClientSetup = { made in made.session = session }
    let model = SoftwareUpdateModel()
    model.restartPoll = .milliseconds(5); model.restartWait = .milliseconds(600)
    return (store, saved, model)
}

@MainActor @Test func oneClickUpdatesAServerAndSaysHowItEnded() async {
    let bridge = UpdatingServer()
    let (store, server, model) = updateStore(bridge)
    await model.refresh(store: store)
    #expect(model.state(for: server).phase == .available(version: "0.2.1", notes: "Faster starts.") && model.state(for: server).coreVersion == "0.1.21")
    #expect(model.staleMachines[server.id] == ["build-box"] && model.canGoBack[server.id] == false)
    #expect(MockHTTPProtocol.recorded(bridge.host).allSatisfy { $0.value(forHTTPHeaderField: HerdrCompatibility.levelHeader) == String(HerdrCompatibility.level) })

    await model.update(server, store: store)
    #expect(model.state(for: server).phase == .updated(to: "0.2.1") && model.state(for: server).bridge?.version == "0.2.1")
    #expect(bridge.appliedVersions == ["0.2.1"], "the server is asked for the version the person was shown")
    #expect(model.canGoBack[server.id] == true)

    await model.update(server, store: store)
    #expect(bridge.appliedVersions == ["0.2.1"], "nothing is installed twice")
    await model.check(server, store: store)
    #expect(model.state(for: server).phase == .upToDate)

    await model.goBack(server, store: store)
    #expect(model.state(for: server).bridge?.version == "0.2.0" && model.canGoBack[server.id] == false)
    #expect(model.state(for: server).line == "Back on workspace 0.2.0. Your agents kept running.")

    await model.updateCore(server, store: store)
    #expect(model.state(for: server).coreNote == "Herdr Core is now 0.1.22 (it was 0.1.21). Herdr on build-box was updated to 0.1.22." && model.staleMachines[server.id] == [])
}

@MainActor @Test func anUpdateThatIsUndoneOrNeverReturnsIsReportedAsThat() async {
    let undone = UpdatingServer(); undone.outcome = .rolledBack
    var (store, server, model) = updateStore(undone)
    await model.refresh(store: store); await model.update(server, store: store)
    #expect(model.state(for: server).phase == .rolledBack(to: "0.2.1", reason: "It never starts.") && model.state(for: server).bridge?.version == "0.2.0")

    let away = UpdatingServer(); away.outcome = .away
    (store, server, model) = updateStore(away)
    await model.refresh(store: store); await model.update(server, store: store)
    guard case .failed(let why) = model.state(for: server).phase else { Issue.record("\(model.state(for: server).phase)"); return }
    #expect(why.contains("has not answered since it began to restart into 0.2.1"))
}

@MainActor @Test func aServerFromBeforeUpdatesAndAServerThatIsDownAreToldApart() async {
    let old = UpdatingServer(); old.versioned = false
    var (store, server, model) = updateStore(old)
    await model.refresh(store: store)
    #expect(model.state(for: server).phase == .manual(HerdrServerUpdate.manualOld) && model.state(for: server).coreVersion == "0.1.21")
    await model.update(server, store: store)
    #expect(old.appliedVersions.isEmpty, "nothing is sent to a server that cannot update itself")

    (store, server, model) = updateStore(UpdatingServer())
    store.herdrClientSetup = { made in made.session = UnreachableProtocol.session }
    await model.refresh(store: store)
    guard case .unreachable(let why) = model.state(for: server).phase else { Issue.record("\(model.state(for: server).phase)"); return }
    #expect(why.contains("not reachable") && !model.state(for: server).isBehind)
    #expect(model.summary(store: store, updater: AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])).headline == "Could not check")
}

/// Software Update renders in each of its states, each differently.
@MainActor @Test func softwareUpdateRendersItsStates() async throws {
    let store = SetupPreview.makeStore(); store.isSetupPreview = false
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    let second = HerdrServer(id: "box1", name: "Studio server", kind: .ssh, address: HerdrServer.loopback(port: HerdrServer.defaultPort), sshHost: "studio.example.com", sshUser: "deploy")
    store.saveHerdrServer(store.herdrServers[0], token: nil); store.saveHerdrServer(second, token: nil)
    let states = HeadlessHerdrShots.updateStates(first: store.herdrServers[0].id, second: second.id)
    #expect(states.count == HeadlessHerdrShots.updates.count)
    var sizes: [Int] = []
    for (index, shown) in states.enumerated() {
        let size = NSSize(width: 570, height: 760)
        let view = SoftwareUpdatePane(preset: shown.model, presetApp: shown.app).padding(28).frame(width: size.width, height: size.height, alignment: .top)
        let data = try #require(await HeadlessSetup.png(view, store: store, updater: updater, size: size))
        #expect(data.count > 4_000, "\(HeadlessHerdrShots.updates[index]) looks blank"); sizes.append(data.count)
    }
    #expect(Set(sizes).count == sizes.count, "each state draws something of its own")
}

private final class ServiceDownloadFixture: URLProtocol, @unchecked Sendable {
    static let received = AwaitableLog<String>()
    static let resumeProgram = Data(repeating: 42, count: 128 * 1024)
    static let resumeOffset = 64 * 1024
    static let stopped = AwaitableLog<String>()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceDownloadFixture.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 18_435 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let range = request.value(forHTTPHeaderField: "Range")
        Self.received.append(path + (range ?? ""))
        let program = path.hasPrefix("/resume/") ? Self.resumeProgram : Data("the program".utf8)
        func respond(_ code: Int, contentRange: String? = nil, data: Data) {
            var headers = ["Content-Length": String(contentRange == nil ? program.count : data.count)]
            if let contentRange { headers["Content-Range"] = contentRange }
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        }

        if path.hasPrefix("/waiting/") {
            respond(200, data: program.prefix(4))
            return
        }
        if path.hasPrefix("/timeout/") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if path.hasPrefix("/damage/") {
            respond(200, data: Data("BAD PROGRAM".utf8))
        } else if range != nil {
            let offset = Self.resumeOffset
            respond(206, contentRange: "bytes \(offset)-\(program.count - 1)/\(program.count)", data: program.dropFirst(offset))
        } else {
            respond(200, data: program.prefix(Self.resumeOffset))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { if let path = request.url?.path { Self.stopped.append(path) } }
}

@Test func theServiceDownloadResumesWithRealByteProgressAndRejectsDamagedBytes() async throws {
    let signed = SignedRelease(program: ServiceDownloadFixture.resumeProgram), data = signed.manifest()
    let release = try WorkspaceRelease.verified(manifest: data, signature: signed.sign(data), publicKey: signed.publicKey)
    var progress: [WorkspaceRelease.DownloadProgress] = []
    defer {
        #expect(progress.contains { $0.attempt == 2 && $0.received == ServiceDownloadFixture.resumeOffset },
                "Progress \(progress) and requests \(ServiceDownloadFixture.received.all)")
    }
    let program = try await release.downloadProgram(for: "x86_64-linux", mirror: "http://127.0.0.1:18435/resume/",
                                                    configuration: ServiceDownloadFixture.configuration, retryDelay: .zero) { progress.append($0) }
    #expect(program == signed.program)
    #expect(progress.last?.received == program.count && progress.last?.total == program.count)
    #expect(ServiceDownloadFixture.received.all.contains { $0.hasPrefix("/resume/") && $0.hasSuffix("bytes=\(ServiceDownloadFixture.resumeOffset)-") })

    let damagedFixture = SignedRelease(), fixtureData = damagedFixture.manifest()
    let original = try WorkspaceRelease.verified(manifest: fixtureData, signature: damagedFixture.sign(fixtureData), publicKey: damagedFixture.publicKey)
    await #expect(throws: WorkspaceRelease.Failure.mismatch) {
        try await original.downloadProgram(for: "x86_64-linux", mirror: "http://127.0.0.1:18435/damage/",
                                          configuration: ServiceDownloadFixture.configuration, retryDelay: .zero) { _ in }
    }
}

@Test func theServiceDownloadStopsOnCancellationAndBoundsTimeoutRetries() async throws {
    let signed = SignedRelease(), data = signed.manifest()
    let release = try WorkspaceRelease.verified(manifest: data, signature: signed.sign(data), publicKey: signed.publicKey)
    let transfer = Task {
        try await release.downloadProgram(for: "x86_64-linux", mirror: "http://127.0.0.1:18435/waiting/",
                                          configuration: ServiceDownloadFixture.configuration, retryDelay: .zero) { _ in }
    }
    try await ServiceDownloadFixture.received.wait { $0.contains { $0.hasPrefix("/waiting/") } }
    transfer.cancel()
    await #expect(throws: CancellationError.self) { try await transfer.value }
    try await ServiceDownloadFixture.stopped.wait { $0.contains { $0.hasPrefix("/waiting/") } }

    await #expect(throws: WorkspaceRelease.Failure.timedOut) {
        try await release.downloadProgram(for: "x86_64-linux", mirror: "http://127.0.0.1:18435/timeout/",
                                          configuration: ServiceDownloadFixture.configuration, retryDelay: .zero) { _ in }
    }
    #expect(ServiceDownloadFixture.received.all.filter { $0.hasPrefix("/timeout/") }.count == 3)
}

@Test func theServiceReusesOnlyAnInstalledBinaryMatchingItsSignedProof() throws {
    let signed = SignedRelease(), data = signed.manifest(target: HerdrLocalService.target)
    let release = try WorkspaceRelease.verified(manifest: data, signature: signed.sign(data), publicKey: signed.publicKey)
    let home = temporaryStore().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = HerdrLocalService(home: home.path)
    try service.place(signed.program)
    #expect(service.matchesInstalledProgram(release))
    #expect(!service.hasVerifiedProgram(publicKey: signed.publicKey))
    service.rememberVerifiedProgram(release)
    #expect(service.hasVerifiedProgram(publicKey: signed.publicKey))
    #expect(!service.hasVerifiedProgram(publicKey: SignedRelease().publicKey))
    try service.place(Data("BAD PROGRAM".utf8))
    #expect(!service.hasVerifiedProgram(publicKey: signed.publicKey))
}
