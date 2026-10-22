import Foundation
import Testing
@testable import AgentApp

private func boxStatus(_ version: Int64 = 11, pending: Bool = true, command: String = "apply --staged",
                       verdict: String = "accept", manifest: String = String(repeating: "a", count: 64)) throws -> String {
    var object: [String: Any] = ["schema": "swarmhub/update-status/1", "state": pending ? "pending_confirm" : "current",
        "detail": pending ? "waiting for confirm" : "applied", "bundle": ["bundle_version": version, "manifest_sha256": manifest],
        "applied_bundle_version": pending ? 0 : version, "confirmed_version": pending ? 0 : version,
        "last": ["command": command, "verdict": verdict, "bundle_version": version], "reload_pending": false,
        "profiles": ["default": ["advertised": ["swarmhub-coding": pending ? "1.0.0" : "1.1.0"]]],
        "pins": ["path": "/usr/local/lib/swarmhub-update/pins.json", "protected": true]]
    if pending {
        object["pending_confirm"] = ["bundle_version": version,
            "code": [["name": "swarmhub-coding", "version": "1.1.0", "kind": "skill"]],
            "data": [["name": "dependent-copy", "version": "1.1.0", "kind": "config", "waits_for": ["swarmhub-coding"]]]]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// What `status` reports after a confirm the busy box deferred: confirmed, nothing pending, the code not yet live.
private func deferredStatus(confirmed: Int64 = 11, applied: Int64 = 0) throws -> String {
    var object = try JSONSerialization.jsonObject(with: Data(try boxStatus(pending: false, command: "apply").utf8)) as! [String: Any]
    object["state"] = "deferred"; object["detail"] = "box busy: code job slot 1"
    object["confirmed_version"] = confirmed; object["applied_bundle_version"] = applied
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func boxTool(_ phase: ToolEvent.Phase, id: String, command: String? = nil, output: String? = nil, exit: Int = 0) -> ToolEvent {
    let result = output.map { String(decoding: try! JSONSerialization.data(withJSONObject: ["output": $0, "exit_code": exit]), as: UTF8.self) }
    return .init(phase: phase, name: "terminal", callID: id, command: command, result: result)
}

@MainActor private func boxStore(applyStatus: String? = nil, readStatus: String? = nil, applyExit: Int = 0,
                                 hold: Bool = false, down: Bool = false, wrongCommand: Bool = false) throws -> (AppStore, Bot, String) {
    let pending = try boxStatus()
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        if request.url!.path.hasSuffix("/chat/stream") {
            if down { return .json(503, ["error": "synthetic unreachable box"]) }
            let instructions = body?["instructions"] as? String ?? ""
            var events: [(String, [String: Any])] = []
            if let applyStatus, let command = instructions.components(separatedBy: "```sh\n").dropFirst().first?.components(separatedBy: "\n```").first {
                events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "apply",
                                            "args": ["command": wrongCommand ? command + "0" : command]]),
                           (applyExit == 0 ? "tool.completed" : "tool.failed", ["tool_name": "terminal", "tool_call_id": "apply",
                               "result": ["output": applyStatus, "exit_code": applyExit]])]
            }
            let output = readStatus ?? pending
            events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "status", "args": ["command": StagedInstall.statusCommand]]),
                       ("tool.completed", ["tool_name": "terminal", "tool_call_id": "status", "result": ["output": output, "exit_code": 0]]),
                       ("assistant.delta", ["delta": "Applied successfully. " + (applyStatus ?? "")]), ("run.completed", [:])]
            return .sse(events, holdOpen: hold ? .milliseconds(200) : nil)
        }
        if request.httpMethod == "DELETE" { return .json(200, ["deleted": true]) }
        if request.url!.path == "/api/sessions" { return .json(201, ["session": ["id": body?["id"] as? String ?? "test"]]) }
        return .json(500, ["error": "synthetic unavailable"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Test box manager", backend: .hermes, hermesProfile: "default")
    bot.canManageBots = true; bot.hermesBaseURL = "https://\(host)/v1"
    store.bots = [bot]
    // Deliberately absent source. Confirm/status/chat never depend on an update host or staged archive source.
    store.boxInstallTransport.boxes = [store.connection(of: bot): .init(source: URL(fileURLWithPath: "/absent-TEST-source"),
        channel: "stable", installID: "TEST-box", versions: ["updater": "1.0.0"], checkpoint: .init())]
    return (store, bot, host)
}

@Test @MainActor func pendingCodeOnlyAppliesAfterThePerBoxClick() async throws {
    let applied = try boxStatus(pending: false, command: "apply")
    let (store, bot, host) = try boxStore(applyStatus: applied, readStatus: applied)
    let pending = try #require(BoxUpdaterStatus.decode(try boxStatus()))
    store.noteBoxUpdaterStatus(pending, on: store.connection(of: bot))
    #expect(pending.pending_confirm?.code.map(\.name) == ["swarmhub-coding"])
    #expect(pending.pending_confirm?.data.first?.waits_for == ["swarmhub-coding"])
    await store.refreshStagedSkills(for: bot)
    #expect(ChatParityServer.requests(host).isEmpty, "opening the skills view never confirms or starts a model turn")
    let click = try #require(store.boxCodeConfirmation(for: bot))
    #expect(click.title == "Apply code update 11 on \(store.connection(of: bot))")
    await store.confirmBoxCode(click, for: bot)
    #expect(store.errorMessage == nil)
    #expect(bot.installedSkills["swarmhub-coding"] == "1.1.0")
    let requests = ChatParityServer.requests(host)
    #expect(requests.filter { $0.path.hasSuffix("/chat/stream") }.count == 1)
    let sent = try #require(requests.first { $0.path.hasSuffix("/chat/stream") }?.body?["instructions"] as? String)
    #expect(sent.contains(click.command) && sent.contains(StagedInstall.statusCommand))
    #expect(!sent.contains("--staged"))
    #expect(requests.contains { $0.method == "DELETE" && $0.path.contains("agentapp_update_status_") })
    #expect(store.boxCodeConfirmation(for: bot) == nil)
}

@Test @MainActor func explicitRefreshReadsPendingWithoutConfirming() async throws {
    let (store, bot, host) = try boxStore()
    await store.refreshStagedSkills(for: bot, onDemand: true)
    let sent = try #require(ChatParityServer.requests(host).first { $0.path.hasSuffix("/chat/stream") }?.body?["instructions"] as? String)
    #expect(!sent.contains(" apply"))
    #expect(store.boxCodeConfirmation(for: bot)?.version == 11)
    #expect(store.boxUpdateState(on: store.connection(of: bot)).highestBundleVersion == 11)
}

@Test @MainActor func staleOrOtherBoxClickNeverSendsAnApply() async throws {
    let (store, bot, host) = try boxStore()
    let target = store.connection(of: bot)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: target)
    let click = try #require(store.boxCodeConfirmation(for: bot))
    let other = Bot(name: "Other box", backend: .hermes, hermesProfile: "default")
    other.canManageBots = true; other.hermesBaseURL = "https://other-box.test/v1"; store.bots.append(other)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: store.connection(of: other))
    await store.confirmBoxCode(click, for: other)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus(12))), on: target)
    await store.confirmBoxCode(click, for: bot)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus(manifest: String(repeating: "b", count: 64)))), on: target)
    await store.confirmBoxCode(click, for: bot)
    #expect(ChatParityServer.requests(host).isEmpty)
    #expect(store.boxCodeConfirmation(for: other)?.version == 11)
    #expect(other.installedSkills.isEmpty)
}

@Test func confirmationNeedsMatchedApplyAndSubsequentStatus() throws {
    let pending = try #require(BoxUpdaterStatus.decode(try boxStatus()))
    let click = try #require(BoxUpdateState.Confirmation(connection: "https://box.test/v1", status: pending))
    let output = try boxStatus(pending: false, command: "apply")
    var call = BoxUpdateConfirmCall(click)
    _ = call.consume(boxTool(.started, id: "early", command: StagedInstall.statusCommand), previous: pending)
    #expect(call.consume(boxTool(.completed, id: "early", output: output), previous: pending) == nil)
    _ = call.consume(boxTool(.started, id: "apply", command: click.command), previous: pending)
    _ = call.consume(boxTool(.completed, id: "unrelated", output: output), previous: pending)
    #expect(!call.succeeded)
    _ = call.consume(boxTool(.completed, id: "apply", output: output), previous: pending)
    #expect(!call.succeeded)
    _ = call.consume(boxTool(.started, id: "status", command: StagedInstall.statusCommand), previous: pending)
    #expect(call.consume(boxTool(.completed, id: "wrong", output: output), previous: pending) == nil)
    #expect(call.consume(boxTool(.completed, id: "status", output: output), previous: pending) != nil)
    #expect(call.succeeded)
    #expect(!click.accepted(try #require(BoxUpdaterStatus.decode(try boxStatus(12, pending: false, command: "apply")))))
}

@Test @MainActor func modelClaimsWrongCommandsAndStaleStatusCannotConfirm() async throws {
    let applied = try boxStatus(pending: false, command: "apply")
    for mode in 0..<4 {
        let (store, bot, _) = try boxStore(applyStatus: mode == 0 ? nil : applied,
            readStatus: mode == 3 ? try boxStatus(12, pending: false, command: "apply") : applied,
            applyExit: mode == 1 ? 75 : 0, wrongCommand: mode == 2)
        store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: store.connection(of: bot))
        let click = try #require(store.boxCodeConfirmation(for: bot))
        await store.confirmBoxCode(click, for: bot)
        #expect(store.errorMessage != nil)
        #expect(bot.installedSkills.isEmpty)
    }
}

@Test @MainActor func codeConfirmIsSingleFlightAndCleansNamespacedSessions() async throws {
    let applied = try boxStatus(pending: false, command: "apply")
    let (store, bot, host) = try boxStore(applyStatus: applied, readStatus: applied, hold: true)
    store.sessionNamespace = "QA-"
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: store.connection(of: bot))
    let click = try #require(store.boxCodeConfirmation(for: bot))
    let task = Task { await store.confirmBoxCode(click, for: bot) }
    try await waitUntil { ChatParityServer.requests(host).contains { $0.path.hasSuffix("/chat/stream") } }
    await store.confirmBoxCode(click, for: bot)
    await store.refreshStagedSkills(for: bot, onDemand: true)
    await task.value
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count == 1)
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" && $0.path.contains("QA-agentapp_update_status_") })
    #expect(store.boxInstallTransport.confirming.isEmpty && store.boxInstallTransport.refreshing.isEmpty)
}

@Test @MainActor func refusedOldClickStillRecordsTheNewerReportedBundle() async throws {
    let newer = try boxStatus(12, command: "apply", verdict: "reject")
    let (store, bot, _) = try boxStore(applyStatus: newer, readStatus: newer, applyExit: 65)
    let target = store.connection(of: bot)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: target)
    await store.confirmBoxCode(try #require(store.boxCodeConfirmation(for: bot)), for: bot)
    #expect(store.boxUpdateState(on: target).highestBundleVersion == 12)
    #expect(bot.installedSkills.isEmpty)
    #expect(store.errorMessage != nil)
}

@Test @MainActor func regressionIsPerBoxAndPersistsAcrossStoreReload() throws {
    let (store, bot, _) = try boxStore()
    let target = store.connection(of: bot)
    for version in [Int64(12), 11] {
        store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus(version))), on: target)
    }
    let record = store.boxUpdateState(on: target)
    #expect(record.highestBundleVersion == 12 && record.reportedBundleVersion == 11 && record.regression)
    #expect(!store.boxUpdateState(on: "https://other-box.test/v1").regression)
    let reloaded = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
        backendFactory: { _ in ChatParityBackend(flags: []) }, keyStore: InMemoryKeyStore([:]), defaults: store.defaults)
    #expect(reloaded.boxUpdateState(on: target) == record)
    #expect(reloaded.boxInstallTransport.status[target] == nil, "offline relaunch keeps the regression without inventing status")
    reloaded.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus(12))), on: target)
    #expect(!reloaded.boxUpdateState(on: target).regression)
}

@Test @MainActor func unreachableBoxKeepsRegressionAndInstalledVersions() async throws {
    let (store, bot, host) = try boxStore(down: true)
    let target = store.connection(of: bot)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus(12))), on: target)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: target)
    bot.installedSkills = ["swarmhub-coding": "1.0.0"]
    let record = store.boxUpdateState(on: target)
    await store.confirmBoxCode(try #require(store.boxCodeConfirmation(for: bot)), for: bot)
    #expect(store.boxUpdateState(on: target) == record)
    #expect(bot.installedSkills == ["swarmhub-coding": "1.0.0"])
    #expect(store.errorMessage?.contains("unconfirmed") == true)
    #expect(ChatParityServer.requests(host).contains { $0.method == "DELETE" })
}

@Test @MainActor func absentBootstrapRecordCannotAuthorizeCode() async throws {
    let (store, bot, host) = try boxStore()
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: store.connection(of: bot))
    let click = try #require(store.boxCodeConfirmation(for: bot))
    store.boxInstallTransport.boxes = [:]
    await store.confirmBoxCode(click, for: bot)
    #expect(ChatParityServer.requests(host).isEmpty)
}

@Test @MainActor func unreachableUpdateSourceDoesNotChangeDirectChatOrStatusRefresh() async throws {
    let (store, bot, host) = try boxStore()
    store.open(bot)
    #expect(store.send(text: "Keep working with the installed skills."))
    try await waitUntil { !store.anyTurnRunning }
    let direct = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }
    #expect(direct.count == 1)
    let instructions = try #require(direct.first?.body?["instructions"] as? String)
    #expect(!instructions.contains("apply --version"), "Direct chat instructions: \(instructions)")
    await store.refreshStagedSkills(for: bot, onDemand: true)
    #expect(store.boxCodeConfirmation(for: bot)?.version == 11)
    #expect(store.boxUpdateState(on: store.connection(of: bot)).highestBundleVersion == 11)
    #expect(store.send(text: "Keep working with the installed skills."))
    try await waitUntil { !store.anyTurnRunning }
    let turns = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }
    #expect(turns.count == 3)
    for turn in turns {
        let sent = try #require(turn.body?["instructions"] as? String)
        #expect(!sent.contains("apply --version"), "Chat/status instructions: \(sent)")
    }
}

@Test func nativeParserRetainsOnlyBoundedVersionConfirmCommands() throws {
    let status = try #require(BoxUpdaterStatus.decode(try boxStatus()))
    let click = try #require(BoxUpdateState.Confirmation(connection: "box", status: status))
    #expect(HermesBackend.updaterStatusCommand(["command": click.command]) == click.command)
    for suffix in ["; echo bad", "\n", " --staged /tmp/x"] {
        #expect(HermesBackend.updaterStatusCommand(["command": click.command + suffix]) == nil)
    }
    #expect(HermesBackend.updaterStatusCommand(["command": StagedInstall.updater + " apply"]) == nil)
    #expect(click.command == StagedInstall.confirmCommand(version: click.version))
    for altered in [StagedInstall.updater + " --max-wait 0 apply --version \(click.version)",
                    click.command.replacingOccurrences(of: "receiver install", with: "receiver uninstall")] {
        #expect(HermesBackend.updaterStatusCommand(["command": altered]) == nil)
    }
}

@Test @MainActor func aDeferredConfirmIsOfferedAgainAsARetry() async throws {
    let deferred = try deferredStatus()
    let (store, bot, _) = try boxStore(applyStatus: deferred, applyExit: 75)
    let target = store.connection(of: bot)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(try boxStatus())), on: target)
    let click = try #require(store.boxCodeConfirmation(for: bot))
    #expect(!click.retry)
    await store.confirmBoxCode(click, for: bot)
    #expect(store.errorMessage?.contains("busy") == true)
    #expect(bot.installedSkills.isEmpty)
    let retry = try #require(store.boxCodeConfirmation(for: bot), "the pane offers the deferred confirm again")
    #expect(retry.retry && retry.version == 11 && retry.command == click.command)
    #expect(retry.title == "Retry code update 11 on \(target)")
    #expect(store.canConfirmBoxCode(retry, for: bot))
    var call = BoxUpdateConfirmCall(retry)  // the retry lands the code: the same receipt and status read accept it
    let applied = try boxStatus(pending: false, command: "apply")
    _ = call.consume(boxTool(.started, id: "apply", command: retry.command), previous: nil)
    _ = call.consume(boxTool(.completed, id: "apply", output: applied), previous: nil)
    _ = call.consume(boxTool(.started, id: "status", command: StagedInstall.statusCommand), previous: nil)
    _ = call.consume(boxTool(.completed, id: "status", output: applied), previous: nil)
    #expect(call.succeeded)
    store.noteBoxUpdaterStatus(try #require(BoxUpdaterStatus.decode(applied)), on: target)
    #expect(store.boxCodeConfirmation(for: bot) == nil)
    // A refresh reading the deferred state offers it too; an unconfirmed or already-applied deferral does not.
    for (status, offered) in [(deferred, true), (try deferredStatus(confirmed: 0), false), (try deferredStatus(applied: 11), false)] {
        let read = try #require(BoxUpdaterStatus.decode(status))
        #expect((BoxUpdateState.Confirmation(connection: target, status: read)?.retry == true) == offered)
    }
}
