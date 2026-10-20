import Foundation
import Testing
@testable import AgentApp

private let stagedNow = "2026-10-20T12:00:00Z"
private let stagedManager = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.0.0")!,
    template: "---\nname: swarmhub-manager\ndescription: Installed by SwarmHub, v{{VERSION}}.\nversion: 1.0.0\n---\nlegacy template\n")
private let stagedFeedback = BundledSkill(name: "swarmhub-feedback", version: SkillVersion("1.0.0")!, template: "legacy feedback")

private func stagedSource() throws -> URL {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = repo.appending(path: "Tests/Fixtures/release-bundles")
    let source = FileManager.default.temporaryDirectory.appending(path: "staged-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixtures.appending(path: "keys/keys-2.json"), to: source.appending(path: "keys.json"))
    for path in ["channels", "bundles", "blobs"] {
        try FileManager.default.copyItem(at: fixtures.appending(path: path), to: source.appending(path: path))
    }
    return source
}

private func stagedBox(_ source: URL) -> StagedInstall.Box {
    .init(source: source, channel: "stable", installID: "TEST-install-0001", versions: ["updater": "1.0.0", "hermes": "0.21.7"],
          checkpoint: .init(keys: 1, index: 4, bundle: 10))
}

private func stagedPackage(_ source: URL, saved: StagedInstall.Floor = .init()) throws -> StagedInstall.Package {
    try StagedInstall.prepare(box: stagedBox(source), saved: saved,
        profiles: [.init(name: "default", coding_order: "codex", skills: ["swarmhub-manager"])], now: stagedNow)
}

private func stagedStatus(_ package: StagedInstall.Package, state: String = "current", version: String = "1.2.0",
                          verdict: String = "accept", profile: String = "default", protected: Bool = true) throws -> String {
    let object: [String: Any] = ["schema": "swarmhub/update-status/1", "state": state, "detail": "test updater status",
        "bundle": ["bundle_version": package.floor.bundle, "manifest_sha256": package.floor.manifest!],
        "last": ["command": "apply --staged", "verdict": verdict, "bundle_version": package.floor.bundle],
        "profiles": [profile: ["status": "applied", "advertised": ["swarmhub-manager": version], "variants": [:]]],
        "reload_pending": false, "pins": ["path": "/usr/local/lib/swarmhub-update/pins.json", "protected": protected]]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Test func stagedBytesAreVerifiedForTheBoxAndRemainOpaque() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    #expect(package.floor.bundle == 11)
    #expect(package.versions["swarm-tools"] == "1.0.0", "box code is transported without being installed on the Mac")
    #expect(package.versions["routine-card"] == nil, "app-only bytes never travel to the box")
    for (path, bytes) in package.files { #expect(try Data(contentsOf: source.appending(path: path)) == bytes) }
    let command = try StagedInstall.command(package)
    #expect(!command.contains("tar ") && !command.contains("legacy template"))
    #expect(command.contains("base64.b64decode") && command.contains("tempfile.mkdtemp"))
    #expect(command.contains("'\(StagedInstall.updater)', '--max-wait', '0', 'apply', '--staged'"))
    #expect(!command.contains("plugins enable") && !command.contains("restart"))
    #expect(try stagedPackage(source, saved: package.floor).floor.manifest == package.floor.manifest, "same bytes may re-render")
    let wrongFloor = StagedInstall.Floor(keys: 2, index: 5, bundle: 11, manifest: String(repeating: "0", count: 64))
    #expect(throws: (any Error).self) { try stagedPackage(source, saved: wrongFloor) }
}

@Test func alteredSourceAndExpiredMetadataNeverProduceInstallInstructions() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let blob = try #require(package.files.keys.first { $0.hasPrefix("blobs/") })
    var altered = try Data(contentsOf: source.appending(path: blob)); altered[600] ^= 1
    try altered.write(to: source.appending(path: blob))
    #expect(throws: (any Error).self) { try stagedPackage(source) }
    try package.files[blob]!.write(to: source.appending(path: blob))
    #expect(throws: (any Error).self) {
        try StagedInstall.prepare(box: stagedBox(source), saved: .init(), profiles: package.profiles, now: "2026-10-27T00:00:00Z")
    }
}

@Test func updaterStatusRequiresTheExactTerminalCallAndProtectedPins() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source), output = try stagedStatus(package)
    var call = UpdaterStatusCall()
    #expect(call.consume(.init(phase: .completed, name: "terminal", callID: "x", result: output)) == nil)
    #expect(call.consume(.init(phase: .started, name: "terminal", callID: "x", command: "echo fabricated status")) == nil)
    #expect(call.consume(.init(phase: .completed, name: "terminal", callID: "x", result: output)) == nil)
    #expect(call.consume(.init(phase: .started, name: "terminal", callID: "status", command: StagedInstall.statusCommand)) == nil)
    #expect(call.consume(.init(phase: .completed, name: "terminal", callID: "other", result: output)) == nil)
    let matched = call.consume(.init(phase: .completed, name: "terminal", callID: "status", result: output))
    #expect(matched?.accepted(package) == true)
    #expect(BoxUpdaterStatus.decode("Installed! " + output) == nil)
    #expect(try BoxUpdaterStatus.decode(stagedStatus(package, protected: false)) == nil)
    #expect(try BoxUpdaterStatus.decode(stagedStatus(package, verdict: "reject"))?.accepted(package) == false)
    let other = StagedInstall.Package(files: package.files, floor: .init(keys: 2, index: 5, bundle: 12, manifest: "another"),
                                      versions: package.versions, profiles: package.profiles)
    #expect(matched?.accepted(other) == false, "a status from a different bundle cannot confirm this one")
    #expect(SkillLibrary.updaterVersions(["swarmhub-manager": "9.8.7", "unknown": "1.0.0"],
                                       names: ["swarmhub-manager"]) == ["swarmhub-manager": "9.8.7"])
}

/// The native Hermes tool parser and real AppStore install/stream/reply path, all on URLProtocol stubs.
@MainActor private func stagedStore(source: URL, status: String?, command: String = StagedInstall.statusCommand,
                                   reply: String = "Installed.", down: Bool = false) -> (AppStore, Bot, String) {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        if request.url!.path.hasSuffix("/chat/stream") {
            if down { return .json(503, ["error": "synthetic box unreachable"]) }
            var events: [(String, [String: Any])] = []
            if let status {
                events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "status", "args": ["command": command]]),
                           ("tool.completed", ["tool_name": "terminal", "tool_call_id": "status", "result": ["output": status, "exit_code": 0]])]
            }
            events += [("assistant.delta", ["delta": reply]), ("run.completed", [:])]
            return .sse(events)
        }
        if request.url!.path == "/api/sessions" { return .json(200, ["session": ["id": "staged-session"]]) }
        return .json(500, ["error": "synthetic unavailable"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore(["hermes.default": "test-key"]), defaults: isolatedDefaults())
    store.now = { Date(timeIntervalSince1970: 1_792_497_600) } // 2026-10-20 12:00 UTC
    let bot = Bot(name: "Test manager", backend: .hermes, hermesProfile: "default")
    bot.canManageBots = true
    store.bots = [bot]; store.selectedBot = bot; store.skillLibraryOverride = [stagedManager]
    store.boxInstallTransport.boxes = [store.connection(of: bot): stagedBox(source)]
    return (store, bot, host)
}

@Test @MainActor func stagedInstallReadsStatusAndIgnoresTheModelsVersion() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let lie = "```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"default\",\"skills\":[{\"name\":\"swarmhub-manager\",\"version\":\"9.9.9\"}]}\n```"
    let (store, bot, host) = stagedStore(source: source, status: try stagedStatus(package), reply: lie)
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"], "actual release version exceeds the compiled fallback")
    let instructions = try #require(ChatParityServer.requests(host).first { $0.path.hasSuffix("/chat/stream") }?.body?["instructions"] as? String)
    #expect(instructions.contains("apply', '--staged'") && instructions.contains(StagedInstall.statusCommand))
    #expect(!instructions.contains("legacy template") && !instructions.contains("mkdir -p ~/.hermes"))
    await store.apply(.skillsInstalled(bot: "default", skills: [.init(name: "swarmhub-manager", version: "8.0.0")]), manager: bot)
    #expect(bot.installedSkills["swarmhub-manager"] == "1.2.0")
}

@Test @MainActor func modelOnlyOrUnrelatedToolOutputCannotClaimStagedSuccess() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    for command in ["echo fabricated status", StagedInstall.statusCommand] {
        let (store, bot, _) = stagedStore(source: source, status: command == StagedInstall.statusCommand ? nil : try stagedStatus(package),
                                         command: command, reply: try stagedStatus(package))
        #expect(store.installSkills(for: bot))
        try await waitUntil { !store.anyTurnRunning }
        #expect(bot.installedSkills.isEmpty)
        #expect(store.errorMessage?.contains("unconfirmed") == true)
    }
}

@Test @MainActor func stagedPendingCodeStaysMissingAndAnUnreachableBoxKeepsTheLastReading() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let (store, bot, _) = stagedStore(source: source, status: try stagedStatus(package, state: "pending_confirm"))
    store.skillLibraryOverride = [stagedManager, stagedFeedback]
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"])
    #expect(store.errorMessage?.contains("pending_confirm") == true)
    let (down, other, _) = stagedStore(source: source, status: nil, down: true)
    other.installedSkills = ["swarmhub-manager": "1.2.0"]
    await down.refreshInstalledSkills(for: other)
    #expect(other.installedSkills == ["swarmhub-manager": "1.2.0"])
}

@Test @MainActor func missingSignedSourceFailsClosedWhileUnbootstrappedBoxesKeepTheLegacyInstaller() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil)
    try FileManager.default.removeItem(at: source.appending(path: "keys.json"))
    #expect(!store.installSkills(for: bot))
    #expect(ChatParityServer.requests(host).isEmpty)
    #expect(bot.installedSkills.isEmpty)
    store.boxInstallTransport.boxes = [:]
    #expect(!store.installSkills(for: bot), "losing the bootstrap record cannot downgrade to raw installation")
    let (old, legacyBot, _) = stagedStore(source: source, status: nil)
    old.boxInstallTransport.boxes = [:]
    let legacy = try #require(old.skillInstallInstructions([stagedManager], profile: "default", botName: legacyBot.name))
    #expect(legacy.contains("legacy template") && !legacy.contains("verified"))
    old.recordInstalled([.init(name: "swarmhub-manager", version: "1.0.0")], profile: "default", manager: legacyBot)
    #expect(legacyBot.installedSkills == ["swarmhub-manager": "1.0.0"])
}

@Test @MainActor func allBotsInstallAlsoUsesOpaqueTransportOnBootstrappedConnections() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil)
    store.skillLibraryOverride = [stagedFeedback]
    #expect(store.installSkillsOnAllBots(manager: bot))
    try await waitUntil { !store.anyTurnRunning }
    let sent = try #require(ChatParityServer.requests(host).first { $0.path.hasSuffix("/chat/stream") }?.body?["instructions"] as? String)
    #expect(sent.contains("apply', '--staged'") && !sent.contains("legacy feedback"))
    #expect(bot.installedSkills.isEmpty)
}
