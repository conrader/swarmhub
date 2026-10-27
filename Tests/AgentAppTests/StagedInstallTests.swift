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
                          verdict: String = "accept", profile: String = "default", protected: Bool = true,
                          reason: String? = nil, detail: String = "test updater status") throws -> String {
    var last: [String: Any] = ["command": "apply --staged", "verdict": verdict, "bundle_version": package.floor.bundle]
    if let reason { last["reason"] = reason }
    let object: [String: Any] = ["schema": "swarmhub/update-status/1", "state": state, "detail": detail,
        "bundle": ["bundle_version": package.floor.bundle, "manifest_sha256": package.floor.manifest!],
        "last": last,
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
    let transfer = try StagedTransfer(package)
    let command = try StagedInstall.command(transfer, profile: "default")
    #expect(!command.contains("tar ") && !command.contains("legacy template"))
    #expect(command.contains("base64.b64decode") && command.contains("tempfile.mkdtemp"))
    #expect(command.contains("?mode=ro") && command.utf8.count < 32_768)
    #expect(transfer.parts.allSatisfy { $0.count <= StagedTransfer.chunkSize })
    for part in transfer.parts { #expect(!command.contains(part.base64EncodedString())) }
    #expect(transfer.hashes.allSatisfy { command.contains($0) })
    #expect(command.contains("'\(StagedInstall.updater)', '--max-wait', '0', 'apply', '--staged'"))
    #expect(!command.contains("plugins enable") && !command.contains("restart"))
    // The webhook receiver is installed again from a live swarmhub-messages copy, after the updater, never failing it.
    let updaterCall = try #require(command.range(of: "'apply', '--staged'"))
    let receiverStep = try #require(command.range(of: "subprocess.run(['/bin/sh', '-c', '\(StagedInstall.receiverCommand)']"))
    #expect(updaterCall.upperBound < receiverStep.lowerBound && command.contains("raise SystemExit(result.returncode)"))
}

@Test func webhookReceiverStepUsesTheLiveSkillPathsAndStaysSilent() {
    let receiver = StagedInstall.receiverCommand
    for profile in ["default", "*"] {
        #expect(receiver.contains(SkillLibrary.installPath("swarmhub-messages", profile: profile) + "/scripts/swarmctl"))
    }
    #expect(receiver.contains("webhook receiver install >/dev/null 2>&1; break;"), "one install per box account, no output")
    #expect(!receiver.contains("'") && !receiver.contains("\\"), "fits in the staged script's quoted Python string")
    let confirm = StagedInstall.confirmCommand(version: 7)
    #expect(confirm == StagedInstall.updater + " --max-wait 0 apply --version 7 && " + receiver, "only after the updater exits 0")
}

@Test func stagedRetryReverifiesTheExactSavedBundleWithoutLoweringFloors() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let retry = try stagedPackage(source, saved: package.floor)
    #expect(retry.floor.manifest == package.floor.manifest && retry.floor.bundle == package.floor.bundle)
    #expect(retry.files == package.files && retry.versions == package.versions, "same bytes may re-render")
    let wrongFloor = StagedInstall.Floor(keys: 2, index: 5, bundle: 11, manifest: String(repeating: "0", count: 64))
    #expect(throws: (any Error).self) { try stagedPackage(source, saved: wrongFloor) }
    for saved in [StagedInstall.Floor(keys: 3, index: 5, bundle: 11, manifest: package.floor.manifest),
                  StagedInstall.Floor(keys: 2, index: 6, bundle: 11, manifest: package.floor.manifest),
                  StagedInstall.Floor(keys: 2, index: 5, bundle: 12, manifest: package.floor.manifest),
                  StagedInstall.Floor(keys: 2, index: 5, bundle: 11)] {
        #expect(throws: (any Error).self) { try stagedPackage(source, saved: saved) }
    }
    let blob = try #require(package.files.keys.first { $0.hasPrefix("blobs/") })
    var altered = try #require(package.files[blob]); altered[600] ^= 1
    try altered.write(to: source.appending(path: blob))
    #expect(throws: (any Error).self) { try stagedPackage(source, saved: package.floor) }
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
                                   reply: String = "Installed.", down: Bool = false, stageOK: Bool = true,
                                   failUpload: Bool = false, holdStatus: Bool = false, cleanupDown: Bool = false,
                                   stageDiagnostic: String? = nil, stageExit: Int = 65,
                                   transferFailure: String? = nil) -> (AppStore, Bot, String) {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        if request.url!.path.hasSuffix("/chat/stream") {
            if down { return .json(503, ["error": "synthetic box unreachable"]) }
            var events: [(String, [String: Any])] = []
            let instructions = body?["instructions"] as? String ?? ""
            if let stage = instructions.components(separatedBy: "````sh\n").dropFirst().first?.components(separatedBy: "\n````").first,
               let prefix = stage.components(separatedBy: "print('SWARMHUB_TRANSFER_OK:").dropFirst().first?.components(separatedBy: "')").first {
                var output = "SWARMHUB_TRANSFER_OK:" + prefix + "\n"
                if let stageDiagnostic,
                   let bytes = try? JSONSerialization.data(withJSONObject: ["exit_code": stageExit, "output": stageDiagnostic]) {
                    output = "SWARMHUB_UPDATER_RESULT:" + prefix + String(decoding: bytes, as: UTF8.self) + "\n"
                } else if let transferFailure, let bytes = try? JSONEncoder().encode(transferFailure) {
                    output = "SWARMHUB_TRANSFER_FAILED:" + prefix + String(decoding: bytes, as: UTF8.self) + "\n"
                }
                events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "stage", "args": ["command": stage]]),
                           (stageOK ? "tool.completed" : "tool.failed", ["tool_name": "terminal", "tool_call_id": "stage",
                              "result": ["output": output, "exit_code": stageOK ? 0 : stageExit]])]
            }
            if let status {
                events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "status", "args": ["command": command]]),
                           ("tool.completed", ["tool_name": "terminal", "tool_call_id": "status", "result": ["output": status, "exit_code": 0]])]
            }
            events += [("assistant.delta", ["delta": reply]), ("run.completed", [:])]
            return .sse(events, holdOpen: holdStatus ? .milliseconds(200) : nil)
        }
        if request.httpMethod == "DELETE" { return .json(cleanupDown ? 503 : 200, ["deleted": !cleanupDown]) }
        if request.url!.path == "/api/sessions" {
            let id = body?["id"] as? String ?? "staged-session"
            if failUpload && id.hasPrefix("agentapp_update_bytes_") { return .json(503, ["error": "synthetic partial upload"]) }
            return .json(201, ["session": ["id": id]])
        }
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

@Test @MainActor func allBotsPrefersSignedByteTransportAndRecordsEachProfileResult() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let raw = try stagedStatus(package)
    var status = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let live: [String: Any] = ["status": "applied", "advertised": ["swarmhub-feedback": "1.0.0"], "variants": [String: String]()]
    status["profiles"] = ["default": live]
    let output = String(decoding: try JSONSerialization.data(withJSONObject: status), as: UTF8.self)
    let (store, manager, host) = stagedStore(source: source, status: output)
    store.skillLibraryOverride = [stagedFeedback]
    let worker = Bot(name: "Worker", backend: .hermes, hermesProfile: "worker")
    store.bots.append(worker)
    #expect(store.installSkillsOnAllBots(manager: manager))
    try await waitUntil { !store.anyTurnRunning && store.skillInstallResults[worker.id] != nil }
    let requests = ChatParityServer.requests(host)
    let turns = requests.filter { $0.path.hasSuffix("/chat/stream") }
    #expect(turns.count == 1, "the updater transfers every selection without embedding any skill bytes")
    let instructions = try #require(turns.first?.body?["instructions"] as? String)
    #expect(instructions.contains("apply', '--staged'"))
    #expect(!instructions.contains("legacy feedback") && !instructions.contains("SWARMHUB_EOF"))
    #expect(requests.contains { ($0.body?["id"] as? String)?.hasPrefix("agentapp_update_bytes_") == true && $0.body?["system_prompt"] != nil })
    #expect(store.allBotsSkillQueue.isEmpty)
    #expect(store.skillInstallResults[manager.id]?.status == .installed)
    #expect(store.skillInstallResults[worker.id]?.status == .failed)
    #expect(manager.skillInstallFailures.isEmpty && worker.skillInstallFailures["swarmhub-feedback"]?.count == 1)
}

@Test @MainActor func stagedProviderPayloadRejectionDoesNotBackOffSkills() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, manager, host) = stagedStore(source: source, status: nil)
    let profiles: [StagedInstall.Profile] = [.init(name: "default", coding_order: "codex", skills: ["swarmhub-manager"])]
    _ = try #require(try store.stagedSkillInstructions(manager: manager, profiles: profiles))
    store.finishStagedSkillInstall(manager: manager, end: .error(BackendError.http(400, "Invalid 'instructions': string too long")))
    #expect(manager.skillInstallFailures.isEmpty && ChatParityServer.requests(host).isEmpty)
    #expect(store.skillInstallResults[manager.id]?.status == .clientPayloadError)
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
        #expect(store.errorMessage?.contains("unconfirmed") != true && store.bots.contains { $0.messages.contains { $0.role == .system && $0.content.contains("unconfirmed") } }, "uxfix1: inline, not the alert")
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
    #expect(store.errorMessage?.contains("pending_confirm") != true && store.bots.contains { $0.messages.contains { $0.role == .system && $0.content.contains("pending_confirm") } }, "uxfix1: inline, not the alert")
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
    let legacy = try #require(try old.skillInstallInstructions([stagedManager], profile: "default", botName: legacyBot.name))
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

@Test @MainActor func carrierBytesUseOnlySessionCreatesAndAreDeletedAfterTheInstall() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: try stagedStatus(stagedPackage(source)))
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning }
    let requests = ChatParityServer.requests(host)
    let carriers = requests.filter { ($0.body?["id"] as? String)?.hasPrefix("agentapp_update_bytes_") == true }
    #expect(!carriers.isEmpty)
    let chatIndex = try #require(requests.firstIndex { $0.path.hasSuffix("/chat/stream") })
    for row in carriers {
        let id = try #require(row.body?["id"] as? String)
        let encoded = try #require(row.body?["system_prompt"] as? String)
        #expect(encoded.utf8.count <= 65_536 && Data(base64Encoded: encoded) != nil)
        #expect(requests[..<chatIndex].contains { $0.body?["id"] as? String == id })
        #expect(requests.contains { $0.method == "DELETE" && $0.path == "/api/sessions/" + id })
        #expect(!requests.contains { $0.path == "/api/sessions/" + id + "/chat/stream" })
    }
    #expect((store.defaults.stringArray(forKey: "updates.transport.cleanup." + store.connection(of: bot)) ?? []).isEmpty)
}

@Test @MainActor func failedCarrierUploadNeverStartsModelAndStillDeletesAmbiguousRows() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil, failUpload: true)
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning }
    let requests = ChatParityServer.requests(host)
    #expect(!requests.contains { $0.path.hasSuffix("/chat/stream") })
    #expect(requests.contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_bytes_") })
    #expect(bot.installedSkills.isEmpty)
}

@Test @MainActor func failedTransferCannotReuseAnOlderSuccessfulStatusForTheSameBundle() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let (store, bot, _) = stagedStore(source: source, status: try stagedStatus(package), stageOK: false)
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.installedSkills.isEmpty)
    #expect(store.errorMessage?.contains("unconfirmed") != true && store.bots.contains { $0.messages.contains { $0.role == .system && $0.content.contains("unconfirmed") } }, "uxfix1: inline, not the alert")
    #expect(store.boxInstallTransport.status[store.connection(of: bot)]?.state == "failed")
}

@Test @MainActor func updaterFailuresReachTheUserAndCacheWithoutAcceptingStaleSuccess() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let rejected = try stagedStatus(package, verdict: "reject", reason: "blob_hash_mismatch")
    let deferred = try stagedStatus(package, state: "deferred", detail: "default deferred: code job running")
    let lock = #"{"state":"deferred","detail":"another swarmhub-update run is active"}"#
    for (diagnostic, code, state, reason) in [
        (rejected, 65, "failed", "blob_hash_mismatch"),
        (deferred, 75, "deferred", "code job running"),
        (lock, 75, "deferred", "another swarmhub-update run is active")
    ] {
        let (store, bot, _) = stagedStore(source: source, status: try stagedStatus(package), stageOK: false,
                                          stageDiagnostic: diagnostic, stageExit: code)
        #expect(store.installSkills(for: bot))
        try await waitUntil { !store.anyTurnRunning }
        #expect(bot.installedSkills.isEmpty, "the later old successful status cannot confirm this turn")
        #expect(store.errorMessage?.contains(reason) != true && store.bots.contains { $0.messages.contains { $0.role == .system && $0.content.contains(reason) } }, "uxfix1: inline, not the alert")
        let cached = try #require(store.boxInstallTransport.status[store.connection(of: bot)])
        #expect(cached.state == state && cached.detail.contains(reason))
        #expect(!cached.accepted(package))
    }
}

@Test @MainActor func transferFailureKeepsItsReasonAndLastKnownVersionsInTheCache() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let (store, bot, _) = stagedStore(source: source, status: try stagedStatus(package), stageOK: false,
                                      transferFailure: "transfer part hash mismatch")
    bot.installedSkills = ["swarmhub-manager": "1.0.0"]
    store.boxInstallTransport.status[store.connection(of: bot)] = BoxUpdaterStatus.decode(try stagedStatus(package, version: "1.0.0"))
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.errorMessage?.contains("Transfer failed: transfer part hash mismatch") != true && store.bots.contains { $0.messages.contains { $0.role == .system && $0.content.contains("Transfer failed: transfer part hash mismatch") } }, "uxfix1: inline, not the alert")
    await store.refreshInstalledSkills(for: bot)
    #expect(bot.installedSkills == ["swarmhub-manager": "1.0.0"])
    #expect(store.boxInstallTransport.status[store.connection(of: bot)]?.state == "failed")
}

private final class StagedClock { var date = Date(timeIntervalSince1970: 1_792_497_600) }

@Test @MainActor func aMixedStagedRequestWaitsForTheBackingOffSkillWithoutSendingOrExtendingItsFailure() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    // Cover a mixed skill list within one profile and an eligible skill in a separate requested profile.
    for separateProfile in [false, true] {
        let (store, bot, host) = stagedStore(source: source, status: nil)
        let clock = StagedClock(); store.now = { clock.date }
        store.skillLibraryOverride = [stagedManager, stagedFeedback]
        let eligible = separateProfile ? Bot(name: "Eligible", backend: .hermes, hermesProfile: "eligible") : bot
        if separateProfile { store.bots.append(eligible) }
        let failure = SkillInstallFailure(version: try #require(package.versions[stagedManager.name]), variant: nil,
                                         count: 1, lastAt: clock.date, reason: "Earlier staged refusal.")
        bot.skillInstallFailures[stagedManager.name] = failure
        let profiles: [StagedInstall.Profile] = separateProfile ? [
            .init(name: "eligible", coding_order: "codex", skills: [stagedFeedback.name]),
            .init(name: "default", coding_order: "codex", skills: [stagedManager.name])
        ] : [.init(name: "default", coding_order: "codex", skills: [stagedFeedback.name, stagedManager.name])]
        #expect(!store.stagedSkillBackingOff(stagedFeedback.name, version: package.versions[stagedFeedback.name], bot: eligible))
        for _ in 0..<2 {
            #expect(try store.stagedSkillInstructions(manager: bot, profiles: profiles) == nil)
            #expect(store.boxInstallTransport.attempts.isEmpty && ChatParityServer.requests(host).isEmpty)
            #expect(bot.skillInstallFailures[stagedManager.name] == failure, "deferral must not extend the cooldown")
            #expect(eligible.skillInstallFailures[stagedFeedback.name] == nil, "no attempt was made for the eligible skill")
            #expect(store.defaults.data(forKey: "updates.transport.floor." + store.connection(of: bot)) == nil)
            #expect(store.errorMessage?.contains("default/swarmhub-manager") == true)
            #expect(store.errorMessage?.contains("Signed skill installs run together") == true)
        }
        // The updater also rerenders saved selections omitted by this caller. Sending only the eligible subset
        // must not bypass the same cooldown, including when an all-bots caller drops a fully backed-off profile.
        let eligibleOnly: [StagedInstall.Profile] = [.init(name: separateProfile ? "eligible" : "default",
                                                          coding_order: "codex", skills: [stagedFeedback.name])]
        #expect(try store.stagedSkillInstructions(manager: bot, profiles: eligibleOnly) == nil)
        #expect(store.boxInstallTransport.attempts.isEmpty && bot.skillInstallFailures[stagedManager.name] == failure)
        // Advance the injected clock to the exact boundary: the original selection and signed bytes can go through.
        clock.date = failure.retryAt
        let unrelated = Bot(name: "Other connection", backend: .hermes, hermesProfile: "default")
        unrelated.hermesBaseURL = "https://unrelated.example.invalid"
        unrelated.skillInstallFailures[stagedManager.name] = SkillInstallFailure(version: failure.version, variant: nil,
                                                                              count: 1, lastAt: clock.date, reason: "Unrelated refusal.")
        store.bots.append(unrelated)
        #expect(try store.stagedSkillInstructions(manager: bot, profiles: profiles) != nil)
        let attempt = try #require(store.boxInstallTransport.attempts[bot.id])
        #expect(attempt.package.profiles.map(\.name) == profiles.map(\.name))
        #expect(attempt.package.profiles.map(\.skills) == profiles.map(\.skills))
        #expect(attempt.package.files == package.files && attempt.package.versions == package.versions)
        #expect(bot.skillInstallFailures[stagedManager.name] == failure)
        let files = try JSONDecoder().decode([String: String].self, from: attempt.transfer.parts.reduce(Data(), +))
        let profileBytes = try #require(files["profiles.json"].flatMap { Data(base64Encoded: $0) })
        let transferred = try JSONDecoder().decode([StagedInstall.Profile].self, from: profileBytes)
        #expect(transferred.map(\.name) == profiles.map(\.name) && transferred.map(\.skills) == profiles.map(\.skills))
    }
}

@Test @MainActor func aFailedStagedInstallBacksOffAtTheSignedVersion() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let (store, bot, host) = stagedStore(source: source, status: try stagedStatus(package), stageOK: false)
    let clock = StagedClock(); store.now = { clock.date }
    let turns = { ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count }
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning && !bot.skillInstallFailures.isEmpty }
    let failure = try #require(store.skillInstallFailure(stagedManager, for: bot))
    #expect(failure.count == 1 && failure.version == "1.2.0" && failure.version == package.versions["swarmhub-manager"],
            "recorded at the signed bundle's version, not the 1.0.0 fallback")
    #expect(failure.reason.contains("unconfirmed") && store.skillInstallBackingOff(stagedManager, for: bot))
    // Backing off: a press sends nothing.
    #expect(!store.installSkills(for: bot) && turns() == 1)
    // After 15 minutes one retry, which goes out unchanged; failing again doubles the wait.
    clock.date += 15 * 60
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning && bot.skillInstallFailures["swarmhub-manager"]?.count == 2 }
    #expect(turns() == 2 && store.skillInstallFailure(stagedManager, for: bot)?.retryAt == clock.date + 30 * 60)
    // A failure at another version does not hold back this bundle: the signed bundle still decides.
    bot.skillInstallFailures["swarmhub-manager"]?.version = "1.1.0"
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning && turns() == 3 }
}

@Test @MainActor func aConfirmedStagedInstallClearsItsFailure() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let (store, bot, _) = stagedStore(source: source, status: try stagedStatus(package))
    bot.skillInstallFailures["swarmhub-manager"] = SkillInstallFailure(version: "1.2.0", variant: nil, count: 1,
        lastAt: Date(timeIntervalSince1970: 1_792_497_600 - 86_400), reason: "Earlier refusal.")
    #expect(store.installSkills(for: bot))
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"] && bot.skillInstallFailures.isEmpty)
}

@Test func stagingDiagnosticsRequireThisTransfersPrefixAndNeverEstablishAcceptance() throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let bytes = try JSONSerialization.data(withJSONObject: ["exit_code": 65, "output": try stagedStatus(package)])
    let output = "SWARMHUB_UPDATER_RESULT:other_" + String(decoding: bytes, as: UTF8.self)
    #expect(StagedTransfer.failure(output, prefix: "this_", previous: nil) == nil)
    #expect(!StagedTransfer.completed(output, prefix: "this_"))
}

@Test @MainActor func transferAndRefreshNamespaceEveryCreatedSessionAndCleanupFindsThem() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    for namespace in ["QA-", AppConstants.selfTestPrefix] {
        let (store, bot, host) = stagedStore(source: source, status: try stagedStatus(stagedPackage(source)))
        store.sessionNamespace = namespace
        #expect(store.installSkills(for: bot))
        try await waitUntil { !store.anyTurnRunning }
        await store.refreshStagedSkills(for: bot, onDemand: true)
        let requests = ChatParityServer.requests(host)
        let created = requests.compactMap { $0.method == "POST" ? $0.body?["id"] as? String : nil }
        #expect(!created.isEmpty && created.allSatisfy { $0.hasPrefix(namespace) })
        let temporary = created.filter { $0.contains("agentapp_update_") }
        #expect(temporary.contains { $0.contains("agentapp_update_bytes_") })
        #expect(temporary.contains { $0.contains("agentapp_update_status_") })
        for id in temporary { #expect(requests.contains { $0.method == "DELETE" && $0.path == "/api/sessions/" + id }) }
        #expect((store.defaults.stringArray(forKey: "updates.transport.cleanup." + store.connection(of: bot)) ?? []).isEmpty)
    }
    #expect(throws: (any Error).self) { try StagedTransfer(stagedPackage(source), namespace: "bad'namespace") }
}

@Test @MainActor func skillsViewOpensSpendNoTurnsAndExplicitRefreshIsSingleFlightAndCleansUp() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let package = try stagedPackage(source)
    let (store, bot, host) = stagedStore(source: source, status: try stagedStatus(package), holdStatus: true)
    await store.refreshInstalledSkills(for: bot)
    await store.refreshInstalledSkills(for: bot)
    #expect(ChatParityServer.requests(host).isEmpty)
    let refresh = Task { await store.refreshStagedSkills(for: bot, onDemand: true) }
    try await waitUntil { ChatParityServer.requests(host).contains { $0.path.hasSuffix("/chat/stream") } }
    await store.refreshStagedSkills(for: bot, onDemand: true)
    await refresh.value
    await store.refreshInstalledSkills(for: bot)
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count == 1)
    let created = ChatParityServer.requests(host).compactMap { $0.body?["id"] as? String }
    #expect(created.count == 1)
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path == "/api/sessions/" + created[0] })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"])
}

@Test @MainActor func failedStatusRefreshDeletesSessionAndKeepsLastGood() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil, down: true)
    bot.installedSkills = ["swarmhub-manager": "1.2.0"]
    await store.refreshStagedSkills(for: bot, onDemand: true)
    #expect(bot.installedSkills == ["swarmhub-manager": "1.2.0"])
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_status_") })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
}

@Test @MainActor func cancellingStatusRefreshStillCleansItsSession() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil, holdStatus: true)
    let refresh = Task { await store.refreshStagedSkills(for: bot, onDemand: true) }
    try await waitUntil { ChatParityServer.requests(host).contains { $0.path.hasSuffix("/chat/stream") } }
    refresh.cancel()
    await refresh.value
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_status_") })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
}

@Test @MainActor func interruptedCleanupIsRetriedBeforeAnotherRefresh() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil)
    let key = "updates.transport.cleanup." + store.connection(of: bot)
    let interrupted = "QA-agentapp_update_bytes_interrupted_0"
    let oldStatus = AppConstants.selfTestPrefix + "agentapp_update_status_interrupted"
    store.defaults.set([interrupted, oldStatus], forKey: key)
    await store.refreshStagedSkills(for: bot, onDemand: true)
    let requests = ChatParityServer.requests(host)
    let deleted = try #require(requests.firstIndex { $0.method == "DELETE" && $0.path == "/api/sessions/" + interrupted })
    let created = try #require(requests.firstIndex { $0.method == "POST" && $0.path == "/api/sessions" })
    #expect(deleted < created)
    #expect(requests[..<created].contains { $0.method == "DELETE" && $0.path == "/api/sessions/" + oldStatus })
    #expect((store.defaults.stringArray(forKey: key) ?? []).isEmpty)
}

@Test @MainActor func failedCleanupRetainsIDsAndBlocksMoreTemporarySessions() async throws {
    let source = try stagedSource(); defer { try? FileManager.default.removeItem(at: source) }
    let (store, bot, host) = stagedStore(source: source, status: nil, cleanupDown: true)
    let key = "updates.transport.cleanup." + store.connection(of: bot)
    let interrupted = "QA-agentapp_update_status_interrupted"
    store.defaults.set([interrupted], forKey: key)
    await store.refreshStagedSkills(for: bot, onDemand: true)
    await store.refreshStagedSkills(for: bot, onDemand: true)
    #expect(store.defaults.stringArray(forKey: key) == [interrupted])
    #expect(!ChatParityServer.requests(host).contains { $0.method == "POST" })
    #expect(store.boxInstallTransport.refreshing.isEmpty)
}
