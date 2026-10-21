import Foundation
import Testing
@testable import AgentApp

// Skill dev mode on a bootstrapped (staged, signed) connection: the profile row carries `dev_mode` (and a Reset's
// `reset`) only when used, the signed bundle and its verification are untouched, and a skill the updater reports as
// modified is never a failure, so it never defers the connection's signed installs. Fixture bundle: TEST keys only.

private let devStagedNow = "2026-10-20T12:00:00Z"
private let devStagedManager = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.0.0")!,
    template: "---\nname: swarmhub-manager\ndescription: Installed by SwarmHub, v{{VERSION}}.\nversion: 1.0.0\n---\nlegacy template\n")

private func devStagedSource() throws -> URL {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = repo.appending(path: "Tests/Fixtures/release-bundles")
    let source = FileManager.default.temporaryDirectory.appending(path: "devmode-staged-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixtures.appending(path: "keys/keys-2.json"), to: source.appending(path: "keys.json"))
    for path in ["channels", "bundles", "blobs"] {
        try FileManager.default.copyItem(at: fixtures.appending(path: path), to: source.appending(path: path))
    }
    return source
}

private func devStagedBox(_ source: URL) -> StagedInstall.Box {
    .init(source: source, channel: "stable", installID: "TEST-install-0001", versions: ["updater": "1.0.0", "hermes": "0.21.7"],
          checkpoint: .init(keys: 1, index: 4, bundle: 10))
}

private func devStagedPackage(_ source: URL) throws -> StagedInstall.Package {
    try StagedInstall.prepare(box: devStagedBox(source), saved: .init(),
        profiles: [.init(name: "default", coding_order: "codex", skills: ["swarmhub-manager"])], now: devStagedNow)
}

/// The updater's status after the apply: the manager skill advertised at `version`, `modified` as reported (nil: no key).
private func devStagedStatus(_ package: StagedInstall.Package, version: String, modified: [String]?) throws -> String {
    var profile: [String: Any] = ["status": "applied", "advertised": ["swarmhub-manager": version], "variants": [:]]
    if let modified { profile["modified"] = modified }
    let object: [String: Any] = ["schema": "swarmhub/update-status/1", "state": "current", "detail": "test updater status",
        "bundle": ["bundle_version": package.floor.bundle, "manifest_sha256": package.floor.manifest!],
        "last": ["command": "apply --staged", "verdict": "accept", "bundle_version": package.floor.bundle],
        "profiles": ["default": profile],
        "reload_pending": false, "pins": ["path": "/usr/local/lib/swarmhub-update/pins.json", "protected": true]]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private final class DevStagedClock { var date = Date(timeIntervalSince1970: 1_792_497_600) } // 2026-10-20 12:00 UTC

/// A bootstrapped manager on `default` whose turns stage, then read `status` from the fixed status command.
@MainActor private func devStagedStore(source: URL, status: String) -> (AppStore, Bot, String, DevStagedClock) {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        if request.url!.path.hasSuffix("/chat/stream") {
            var events: [(String, [String: Any])] = []
            let instructions = body?["instructions"] as? String ?? ""
            if let stage = instructions.components(separatedBy: "````sh\n").dropFirst().first?.components(separatedBy: "\n````").first,
               let prefix = stage.components(separatedBy: "print('SWARMHUB_TRANSFER_OK:").dropFirst().first?.components(separatedBy: "')").first {
                events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "stage", "args": ["command": stage]]),
                           ("tool.completed", ["tool_name": "terminal", "tool_call_id": "stage",
                              "result": ["output": "SWARMHUB_TRANSFER_OK:" + prefix + "\n", "exit_code": 0]])]
            }
            events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "status", "args": ["command": StagedInstall.statusCommand]]),
                       ("tool.completed", ["tool_name": "terminal", "tool_call_id": "status", "result": ["output": status, "exit_code": 0]]),
                       ("assistant.delta", ["delta": "Installed."]), ("run.completed", [:])]
            return .sse(events)
        }
        if request.httpMethod == "DELETE" { return .json(200, ["deleted": true]) }
        if request.url!.path == "/api/sessions" { return .json(201, ["session": ["id": body?["id"] as? String ?? "staged-session"]]) }
        return .json(500, ["error": "synthetic unavailable"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore(["hermes.default": "test-key"]), defaults: isolatedDefaults())
    let clock = DevStagedClock(); store.now = { clock.date }
    let bot = Bot(name: "Test manager", backend: .hermes, hermesProfile: "default")
    bot.canManageBots = true
    store.bots = [bot]; store.selectedBot = bot; store.skillLibraryOverride = [devStagedManager]
    store.boxInstallTransport.boxes = [store.connection(of: bot): devStagedBox(source)]
    return (store, bot, host, clock)
}

/// The keys of each profiles.json row as the transfer encodes it.
private func encodedKeys(_ profiles: [StagedInstall.Profile]) throws -> [Set<String>] {
    let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles)) as? [[String: Any]] ?? []
    return rows.map { Set($0.keys) }
}

@Test @MainActor func theProfileRowCarriesDevModeOnlyWhenOn() throws {
    let source = try devStagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, _, _) = devStagedStore(source: source, status: "{}")
    let off = store.stagedProfile(for: bot, skills: ["swarmhub-manager"])
    #expect(try encodedKeys([off]) == [["name", "coding_order", "skills"]], "dev mode off: profiles.json as before")
    #expect(off.name == "default" && off.coding_order == store.codingOrder(for: bot).argument && off.skills == ["swarmhub-manager"])
    store.setSkillDevMode(true, for: bot)
    let on = store.stagedProfile(for: bot, skills: ["swarmhub-manager"])
    #expect(on.dev_mode == true && on.reset == nil && (try encodedKeys([on])) == [["name", "coding_order", "skills", "dev_mode"]])
    let reset = store.stagedProfile(for: bot, skills: ["swarmhub-manager"], reset: devStagedManager)
    #expect(reset.reset == ["swarmhub-manager"])
    // The signed bytes and their verification do not depend on the row: the same verified package either way.
    let plain = try devStagedPackage(source)
    let dev = try StagedInstall.prepare(box: devStagedBox(source), saved: .init(), profiles: [reset], now: devStagedNow)
    #expect(dev.files == plain.files && dev.versions == plain.versions && dev.floor.manifest == plain.floor.manifest)
    #expect(throws: StagedInstall.Failure.self) {
        try StagedInstall.prepare(box: devStagedBox(source), saved: .init(), profiles: [.init(name: "default", coding_order: "codex",
            skills: ["swarmhub-manager"], dev_mode: true, reset: ["swarmhub-coding"])], now: devStagedNow)
    }
}

@Test @MainActor func aSkillTheUpdaterKeptIsModifiedLocallyNotAFailure() async throws {
    let source = try devStagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try devStagedPackage(source)
    let (store, bot, host, _) = devStagedStore(source: source, status: try devStagedStatus(package, version: "1.0.0", modified: ["swarmhub-manager"]))
    store.setSkillDevMode(true, for: bot)
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning && !bot.skillsModifiedLocally.isEmpty }
    #expect(bot.skillsModifiedLocally == ["swarmhub-manager"] && bot.installedSkills == ["swarmhub-manager": "1.0.0"])
    #expect(bot.skillInstallFailures.isEmpty && store.errorMessage == nil)
    // Nothing backs off, so the next signed install is not deferred: Reset to bundled goes out at once.
    #expect(store.resetSkillToBundled(devStagedManager, for: bot))
    let attempt = try #require(store.boxInstallTransport.attempts[bot.id])
    #expect(attempt.package.profiles.first?.reset == ["swarmhub-manager"] && attempt.package.profiles.first?.dev_mode == true)
    try await waitUntil { !store.anyTurnRunning }
    let turns = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }
    #expect(turns.count == 2)
}

@Test @MainActor func aResetThatLandsClearsTheMark() async throws {
    let source = try devStagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try devStagedPackage(source)
    let (store, bot, _, _) = devStagedStore(source: source, status: try devStagedStatus(package, version: "1.2.0", modified: []))
    store.setSkillDevMode(true, for: bot)
    bot.skillsModifiedLocally = ["swarmhub-manager"]
    #expect(store.resetSkillToBundled(devStagedManager, for: bot))
    try await waitUntil { !store.anyTurnRunning && bot.skillsModifiedLocally.isEmpty }
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"] && bot.skillInstallFailures.isEmpty)
}

@Test @MainActor func devModeOffAnUnconfirmedStagedSkillStillFailsAndBacksOff() async throws {
    // REGRESSION: without dev mode the same reading is today's unconfirmed install, a failure at the signed version,
    // even if the updater (e.g. a stale profiles.json) listed it as modified.
    let source = try devStagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try devStagedPackage(source)
    let (store, bot, _, _) = devStagedStore(source: source, status: try devStagedStatus(package, version: "1.0.0", modified: ["swarmhub-manager"]))
    #expect(store.installSkills(for: bot))
    let attempt = try #require(store.boxInstallTransport.attempts[bot.id])
    #expect(attempt.package.profiles.first?.dev_mode == nil && attempt.package.profiles.first?.reset == nil)
    try await waitUntil { !store.anyTurnRunning && !bot.skillInstallFailures.isEmpty }
    #expect(bot.skillInstallFailures["swarmhub-manager"]?.version == "1.2.0" && bot.skillsModifiedLocally.isEmpty)
    #expect(store.skillInstallBackingOff(devStagedManager, for: bot) && !store.installSkills(for: bot))
}

@Test @MainActor func aDevModeConnectionStillDefersWhileAnotherSkillBacksOff() throws {
    // Dev mode does not loosen the backoff: a real failure at the bundle's version still holds back every signed send.
    let source = try devStagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try devStagedPackage(source)
    let (store, bot, host, clock) = devStagedStore(source: source, status: try devStagedStatus(package, version: "1.2.0", modified: []))
    store.setSkillDevMode(true, for: bot)
    bot.skillInstallFailures["swarmhub-manager"] = SkillInstallFailure(version: "1.2.0", variant: nil, count: 1, lastAt: clock.date, reason: "Refused.")
    #expect(!store.resetSkillToBundled(devStagedManager, for: bot) && store.errorMessage?.contains("deferred") == true)
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.isEmpty)
}
