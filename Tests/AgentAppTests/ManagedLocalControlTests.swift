import Foundation
import Testing
@testable import AgentApp

// Cross-review finding 6: the real ManagedLocalControl subprocess path (profile layout, HERMES_HOME, stdin JSON,
// decoding real `swarmctl control get` output, the receipt after `control decide`) against the shipped scripts
// installed in a temporary HOME. The record is a FAKE owner-gated prod action: nothing executes; no gateway, model or
// outbound. Needs python3 on PATH, like swiftSecretWriterHandsOffToTheRealPythonProvisioningValidator.
// On the Mac: swift test --filter ManagedLocalControlTests

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let localAddress = "http://127.0.0.1:8642/v1"

/// A temporary HOME where the messaging scripts are the `coordinator` profile's skill and `worker` is another profile.
private final class RuntimeHome {
    let home: URL
    let scripts: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "swarmhub-control-\(UUID().uuidString)")
        scripts = home.appending(path: ".hermes/profiles/coordinator/skills/swarmhub/swarmhub-messages/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".hermes/profiles/worker"), withIntermediateDirectories: true)
        let shipped = repoRoot.appending(path: "Resources/Skills/swarmhub-messages/scripts")
        for name in try FileManager.default.contentsOfDirectory(atPath: shipped.path) where !name.hasPrefix("__") {
            try FileManager.default.copyItem(at: shipped.appending(path: name), to: scripts.appending(path: name))
        }
    }

    /// `swarmctl <arguments>` as the coordinator profile's gateway would run it; stdout and stderr together.
    func swarmctl(_ arguments: [String], stdin: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", scripts.appending(path: "swarmctl").path] + arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
                               "HERMES_HOME": home.appending(path: ".hermes/profiles/coordinator").path]
        process.standardOutput = output; process.standardError = output; process.standardInput = input
        try process.run()
        if let stdin { try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Owner policy plus one FAKE, owner-gated prod action whose spec carries fields beyond the old known-key set.
    func submitFakeProdAction() throws -> String {
        let policy = try swarmctl(["policy", "set"], stdin: #"{"owner":"coordinator"}"#)
        guard policy.status == 0 else { throw FixtureError.command(policy.output) }
        let spec = #"{"kind":"prod","bot":"worker","intent":"B-operation","argv":["/bin/echo","FAKE B"],"risks":["prod"],"fake":true,"speculative":false}"#
        let submitted = try swarmctl(["submit"], stdin: spec)
        let task = submitted.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard submitted.status == 0, ManagedApproval.validTask(task) != nil else { throw FixtureError.command(submitted.output) }
        return task
    }

    /// swarmctl starts a detached recovery worker under this HOME; stop it (supervisor first) before removing the tree.
    func stop() {
        let folder = home.appending(path: ".hermes/swarmhub")
        for name in ["job-wake.supervisor.pid", "job-wake.pid"] {
            let file = folder.appending(path: name)
            var waited = 0
            while !FileManager.default.fileExists(atPath: file.path) && waited < 30 { usleep(100_000); waited += 1 }
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGTERM)
            }
        }
        usleep(200_000)
        try? FileManager.default.removeItem(at: home)
    }

    enum FixtureError: Error { case command(String) }
}

@MainActor @Test func realControlGetCardDecideAndReceiptBindTheRuntimeRecord() async throws {
    let runtime = try RuntimeHome(); defer { runtime.stop() }
    let task = try runtime.submitFakeProdAction()
    let record = try await ManagedLocalControl.request(address: localAddress, profile: "coordinator", verb: "get", task: task, input: nil, home: runtime.home)
    #expect(record.id == task && record.gate == "owner" && record.status == "awaiting-owner" && record.decider == "coordinator" && record.awaiting)
    #expect(record.fingerprint.count == 64 && record.decided_by == nil && record.decided_at == nil)
    #expect(record.spec.kind == "prod" && record.spec.bot == "worker" && record.spec.intent == "B-operation" && record.spec.fake == true)
    #expect(record.spec.argv == ["/bin/echo", "FAKE B"] && record.spec.risks == ["prod"] && record.spec.fields["speculative"] == .bool(false))
    // The card renders the complete fingerprinted spec, including fields the old struct dropped (finding 7).
    let card = try record.request(botID: UUID())
    #expect(card.requestID == task && card.profile == "coordinator" && card.actionKind == "managed.prod" && card.managedRecord == record)
    let shown = try #require(card.command)
    for field in ["\"argv\"", "FAKE B", "\"risks\"", "\"fake\" : true", "\"speculative\" : false", "\"intent\" : \"B-operation\""] {
        #expect(shown.contains(field), "\(field)")
    }
    // A stale fingerprint is refused inside the runtime's transaction; the record stays awaiting.
    let stale = try JSONSerialization.data(withJSONObject: ["approved": true, "fingerprint": String(repeating: "a", count: 64), "gate": "owner"])
    await #expect(throws: ManagedControlError.self) {
        try await ManagedLocalControl.request(address: localAddress, profile: "coordinator", verb: "decide", task: task, input: stale, home: runtime.home)
    }
    let unchanged = try await ManagedLocalControl.request(address: localAddress, profile: "coordinator", verb: "get", task: task, input: nil, home: runtime.home)
    #expect(unchanged == record && unchanged.awaiting)
    // The bound decision yields a receipt that confirms exactly this record.
    let bound = try JSONSerialization.data(withJSONObject: ["approved": true, "fingerprint": record.fingerprint, "gate": record.gate])
    let receipt = try await ManagedLocalControl.request(address: localAddress, profile: "coordinator", verb: "decide", task: task, input: bound, home: runtime.home)
    #expect(receipt.confirms(true, original: record) && !receipt.confirms(false, original: record))
    #expect(receipt.decided_by == "coordinator" && receipt.decided_at != nil && ["queued", "running", "done"].contains(receipt.status), "\(receipt.status)")
    // Only a local address and an installed control script are accepted.
    await #expect(throws: ManagedControlError.self) {
        try await ManagedLocalControl.request(address: "http://box.example.invalid:8642/v1", profile: "coordinator", verb: "get", task: task, input: nil, home: runtime.home)
    }
    await #expect(throws: ManagedControlError.self) {
        try await ManagedLocalControl.request(address: localAddress, profile: "worker", verb: "get", task: task, input: nil, home: runtime.home)
    }
}

@MainActor @Test func theAppApprovesARealRuntimeRecordThroughSwarmctlAndRemovesTheCardOnItsReceipt() async throws {
    let runtime = try RuntimeHome(); defer { runtime.stop() }
    let task = try runtime.submitFakeProdAction()
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    bot.hermesProfile = "coordinator"; bot.hermesBaseURL = localAddress
    store.managedHome = runtime.home
    // The fence lies about kind, gate and content; only the runtime record reaches the card.
    let fence = "Awaiting you.\n```swarmhub\n{\"op\":\"approval\",\"task\":\"\(task)\",\"kind\":\"read\",\"gate\":\"coordinator\",\"decider\":\"coordinator\",\"bot\":\"worker\",\"intent\":\"lying fence\",\"summary\":\"harmless read\"}\n```"
    store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: fence), bot: bot)
    try await waitUntil { store.approvals.count == 1 }
    let card = try #require(store.approvals.first)
    #expect(card.actionKind == "managed.prod" && card.profile == "coordinator" && card.command?.contains("FAKE B") == true)
    #expect(!card.summary.contains("harmless read") && card.managedRecord?.gate == "owner" && bot.approvalAudit.last?.outcome == .asked)
    store.decideManagedAction(card, approved: true)
    #expect(store.approvals.first?.decisionPending == true)
    try await waitUntil { store.approvals.isEmpty }
    #expect(bot.approvalAudit.last?.outcome == .approved && store.errorMessage == nil)
    let after = try runtime.swarmctl(["control", "get", task])
    #expect(after.status == 0 && after.output.contains("\"decided_by\": \"coordinator\"") && !after.output.contains("awaiting-owner"), "\(after.output)")
    #expect(!bot.messages.contains { $0.role == .user }, "no model turn stands in for the receipt")
}
