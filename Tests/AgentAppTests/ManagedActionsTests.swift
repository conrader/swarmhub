import Foundation
import Testing
@testable import AgentApp

// Gap closures after live pass 4: managed approvals become real cards and the decision goes back as the deciding bot's
// turn (P07); Send on a draft card binds to a managed outbound record (P07); secret requests open the entry sheet and
// the bot gets a 0600 file's path (P06). Scripted backend, temp folders; no network, no swarmctl.

private let taskID = "task.0123456789abcdef0123456789abcdef"
private let approvalReply = "Submitted.\n```swarmhub\n{\"op\":\"approval\",\"task\":\"\(taskID)\",\"kind\":\"outbound\",\"gate\":\"coordinator\",\"decider\":\"jarvis\",\"bot\":\"infra\",\"intent\":\"draft-1\",\"summary\":\"Email Ada the release note\",\"risks\":[],\"draft\":\"Hello Ada\"}\n```"
private let secretReply = "I need the key.\n```swarmhub\n{\"op\":\"secret_request\",\"name\":\"openai-key\",\"reason\":\"to provision QA Hermes\"}\n```"

@MainActor private func finish(_ backend: ScriptedTurnBackend, _ text: String) async {
    await backend.emit(.token(text), .completed); await backend.end()
}

// Shared with the Linux Python mirror. These assertions still require macOS/Swift to execute.
@Test func managedActionRepliesAcceptOnlyFencesOrOneWholeJSONObject() throws {
    struct Fixture: Decodable { let name: String; let text: String; let tasks: [String]; let names: [String] }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/managed_action_replies.json")
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    for fixture in fixtures {
        #expect(ManagedApproval.parse(in: fixture.text).map(\.task) == fixture.tasks, "\(fixture.name)")
        #expect(SecretRequest.parse(in: fixture.text).map(\.name) == fixture.names, "\(fixture.name)")
    }
    let bare = try #require(SwarmhubBlock.fences(in: approvalReply).first?.body)
    #expect(ManagedApproval.parse(in: bare) == ManagedApproval.parse(in: approvalReply))
    let bareSecret = try #require(SwarmhubBlock.fences(in: secretReply).first?.body)
    #expect(SecretRequest.parse(in: bareSecret) == SecretRequest.parse(in: secretReply))
}

@Test func approvalBlocksBecomeManagedApprovals() throws {
    let found = ManagedApproval.parse(in: approvalReply)
    let item = try #require(found.first)
    #expect(found.count == 1 && item.task == taskID && item.kind == "outbound" && item.gate == "coordinator" && item.decider == "jarvis" && item.bot == "infra")
    #expect(item.intent == "draft-1" && item.summary == "Email Ada the release note" && item.risks.isEmpty && item.draft == "Hello Ada")
    #expect(item.cardID == UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef"), "the task id is the card id")
    #expect(item.cardID == ManagedApproval.parse(in: approvalReply).first?.cardID)
    let request = item.request(botID: nil, profile: "jarvis")
    #expect(request.isManaged && request.actionKind == "managed.outbound" && request.requestID == taskID && request.profile == "jarvis")
    #expect(request.title == "Outbound action awaits the coordinator: draft-1" && !request.hasKnownCommand)
    #expect(request.command == nil && request.draft == "Hello Ada")
    #expect(request.summary == "Email Ada the release note · submitted by infra · \(taskID)")
    // Invalid task ids, kinds, gates and profiles are ignored or dropped; other ops are not approvals.
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"rm -rf\",\"kind\":\"outbound\",\"gate\":\"owner\"}\n```").isEmpty)
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"task.a\",\"kind\":\"shell\",\"gate\":\"owner\"}\n```").isEmpty)
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"task.a\",\"kind\":\"prod\",\"gate\":\"anyone\"}\n```").isEmpty)
    let odd = try #require(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"task.a\",\"kind\":\"prod\",\"gate\":\"owner\",\"decider\":\"../x\",\"risks\":[\"prod\",\"bogus\"]}\n```").first)
    #expect(odd.decider == nil && odd.risks == ["prod"] && odd.draft == nil && odd.title == "Prod action awaits the owner: ")
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"goal\",\"status\":\"done\"}\n```").isEmpty)
    #expect(ManagedApproval.profileName("jarvis\n") == nil && ManagedApproval.validTask(taskID + "\n") == nil)
}

@Test func draftSendBindsToAManagedOutboundRecord() {
    let source = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let intent = ManagedOutbound.intent(sourceID: source, index: 2)
    #expect(intent == "draft-11111111-2222-3333-4444-555555555555-2" && intent == ManagedOutbound.intent(sourceID: source, index: 2))
    let draft = DraftCard(to: "ada@example.invalid", subject: "Release", body: "Hello Ada,\nit shipped.")
    let spec = ManagedOutbound.spec(draft: draft, bot: "infra", intent: intent)
    #expect(spec == "{\"bot\":\"infra\",\"fake\":true,\"intent\":\"\(intent)\",\"kind\":\"outbound\",\"text\":\"Subject: Release\\n\\nHello Ada,\\nit shipped.\",\"to\":\"ada@example.invalid\"}")
    let text = ManagedOutbound.instruction(draft: draft, bot: "infra", intent: intent)
    #expect(text.hasPrefix("[SwarmHub draft send]") && text.contains("scripts/swarmctl submit <<'SWARMHUB_DRAFT'\n\(spec)\nSWARMHUB_DRAFT"))
    #expect(text.contains("This record is FAKE") && !text.contains("Send it") && !text.contains("Replace only the recipient placeholder"))
    let open = ManagedOutbound.instruction(draft: DraftCard(to: nil, subject: nil, body: "Hi"), bot: "infra", intent: intent)
    #expect(open.contains("\"to\":\"<recipient named in this thread>\"") && open.contains("Replace only the recipient placeholder") && open.contains("FAKE"))
    #expect(text.contains("never invent a pending approval"))
}

@MainActor @Test func sendOnADraftCardSubmitsTheManagedRecordInsteadOfSendIt() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    store.defaults.set(true, forKey: "managedOutboundLive") // Even a stale preference cannot enable real outbound.
    #expect(store.submitComposer(text: "draft a note to Ada"))
    try await waitUntil { await backend.streamCount == 1 }
    await finish(backend, "Here you go.\n```draft\nTo: ada@example.invalid\nSubject: Release\n\nHello Ada\n```")
    try await waitUntil { store.isIdle(bot) }
    let reply = try #require(bot.messages.last { $0.role == .assistant })
    let blocks = ChatCardParser.parse(reply.content)
    let index = try #require(blocks.firstIndex { if case .draft = $0 { true } else { false } })
    #expect(store.performCardAction(target: .bot(botID: bot.id, threadID: nil), sourceID: reply.id, index: index, expected: blocks[index]))
    let intent = ManagedOutbound.intent(sourceID: reply.id, index: index)
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:[SwarmHub draft send]") && $0.contains("\"intent\":\"\(intent)\"") && $0.contains("\"fake\":true") } }
    #expect(reply.metadata["draftSent.\(index)"] == intent, "the card remembers the record it is bound to")
    #expect(!store.performCardAction(target: .bot(botID: bot.id, threadID: nil), sourceID: reply.id, index: index, expected: blocks[index]), "a second Send is refused")
    #expect(!bot.messages.contains { $0.role == .user && $0.content == "Send it" })
}

private func runtimeRecord(status: String = "awaiting-coordinator", decided: Bool = false) -> ManagedRecord {
    ManagedRecord(id: taskID, fingerprint: String(repeating: "b", count: 64), gate: "coordinator", status: status,
                  decider: "default", spec: .init(kind: "outbound", bot: "infra", intent: "actual-B",
                  risks: ["prod"], argv: ["/bin/echo", "FAKE B"], to: "b@example.invalid", text: "Exact B draft", fake: true),
                  decided_by: decided ? "default" : nil, decided_at: decided ? 123 : nil)
}

@MainActor @Test func aFenceDescribingActionAForTaskBDisplaysOnlyRuntimeBAndCannotApproveA() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    let record = runtimeRecord()
    var runtime = record
    store.managedControl = { _, verb, task, input in
        #expect(task == taskID)
        if verb == "decide" {
            let input = try #require(input)
            let payload = try #require(try JSONSerialization.jsonObject(with: input) as? [String: Any])
            #expect(payload["fingerprint"] as? String == record.fingerprint)
            #expect(payload["gate"] as? String == record.gate)
            runtime = runtimeRecord(status: "queued", decided: true)
        }
        return runtime
    }
    store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: approvalReply), bot: bot)
    try await waitUntil { store.approvals.count == 1 }
    let card = try #require(store.approvals.first)
    #expect(card.draft == "Exact B draft" && card.command?.contains("b@example.invalid") == true)
    #expect(!card.summary.contains("Hello Ada") && card.summary.contains("actual-B"))
    // An old fence-built A card, even with B's task id, is never eligible to decide.
    let unverified = try #require(ManagedApproval.parse(in: approvalReply).first).request(botID: bot.id, profile: "default")
    store.decideManagedAction(unverified, approved: true)
    #expect(store.approvals.count == 1 && runtime.awaiting)
    store.decideManagedAction(card, approved: true)
    #expect(store.approvals.first?.decisionPending == true)
    try await waitUntil { store.approvals.isEmpty }
    #expect(bot.approvalAudit.last?.outcome == .approved)
    #expect(!bot.messages.contains { $0.role == .user }, "a model turn cannot stand in for a receipt")
}

@MainActor @Test func failedOrUnexecutedManagedDecisionsKeepRetryableCards() async throws {
    for mode in ["transport", "rejected", "neverExecuted"] {
        let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
        let original = runtimeRecord()
        store.managedControl = { _, verb, _, _ in
            if verb == "decide" {
                if mode == "transport" { throw URLError(.networkConnectionLost) }
                if mode == "rejected" { throw ManagedControlError.rejected }
                return original // No runtime decision: a successful transport alone is insufficient.
            }
            return original
        }
        store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: approvalReply), bot: bot)
        try await waitUntil { store.approvals.count == 1 }
        let card = try #require(store.approvals.first)
        store.decideManagedAction(card, approved: true)
        try await waitUntil { store.approvals.first?.decisionPending == false }
        #expect(store.approvals.count == 1 && bot.approvalAudit.last?.outcome == .asked)
        store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: approvalReply), bot: bot)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.approvals.count == 1)
        store.managedControl = { _, _, _, _ in runtimeRecord(status: "queued", decided: true) }
        store.decideManagedAction(try #require(store.approvals.first), approved: true)
        try await waitUntil { store.approvals.isEmpty }
        #expect(bot.approvalAudit.last?.outcome == .approved)
    }
}

@MainActor @Test func staleManagedRecordCannotBeApprovedAndPendingSurvivesPersistence() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    let original = runtimeRecord()
    store.approvals = [try original.request(botID: bot.id)]
    store.approvals[0].decisionPending = true
    let saved = try StoreFile.decode(JSONEncoder().encode(store.storeFile))
    #expect(saved.managedApprovals?.first?.decisionPending == true)
    store.managedControl = { _, verb, _, _ in
        #expect(verb == "get", "an uncertain decision must be queried before any retry")
        return original
    }
    store.decideManagedAction(try #require(store.approvals.first), approved: true)
    try await waitUntil { store.approvals.first?.decisionPending == false }
    #expect(bot.approvalAudit.isEmpty)
    let changed = ManagedRecord(id: taskID, fingerprint: String(repeating: "c", count: 64), gate: "coordinator",
                                status: "awaiting-coordinator", decider: "default", spec: original.spec)
    store.managedControl = { _, verb, _, _ in #expect(verb == "get"); return changed }
    store.decideManagedAction(try #require(store.approvals.first), approved: true)
    try await waitUntil { store.approvals.first?.decisionPending == false }
    #expect(store.approvals.count == 1 && bot.approvalAudit.isEmpty)
}

@MainActor @Test func missingControlInterfaceNeverMakesAModelFenceAnApproval() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    store.managedControl = { _, _, _, _ in throw ManagedControlError.unavailable }
    store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: approvalReply), bot: bot)
    try await waitUntil { store.errorMessage != nil }
    #expect(store.approvals.isEmpty && bot.approvalAudit.isEmpty)
}

@Test func secretRequestsAreParsedAndFilesAreWrittenOwnerOnly() throws {
    let request = try #require(SecretRequest.parse(in: secretReply).first)
    #expect(request.name == "openai-key" && request.reason == "to provision QA Hermes")
    #expect(SecretRequest.parse(in: "```swarmhub\n{\"op\":\"secret_request\",\"name\":\"../etc/passwd\"}\n```").isEmpty)
    #expect(SecretRequest.validName("key\n") == nil)
    let folder = FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString)")
    let url = try SecretFileWriter.write("sk-test-value\n", name: request.name, in: folder)
    #expect(url == folder.appending(path: "openai-key") && (try? String(contentsOf: url, encoding: .utf8)) == "sk-test-value")
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
    let message = SecretFileWriter.message(for: request, at: url)
    #expect(message.contains(url.path) && !message.contains("sk-test-value") && message.contains("0600"))
    #expect(throws: SecretFileError.self) { try SecretFileWriter.write("  \n", name: "k", in: folder) }
    #expect(throws: SecretFileError.self) { try SecretFileWriter.write("v", name: "bad name", in: folder) }
    #expect(throws: SecretFileError.self) { try SecretFileWriter.write(String(repeating: "x", count: 65537), name: "k", in: folder) }
    let target = folder.appending(path: "public")
    try Data("unchanged".utf8).write(to: target)
    let linked = folder.appending(path: "linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
    try SecretFileWriter.write("replacement", name: "linked", in: folder)
    #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
    #expect(try String(contentsOf: linked, encoding: .utf8) == "replacement")
    #expect(try FileManager.default.attributesOfItem(atPath: linked.path)[.posixPermissions] as? Int == 0o600)
    try? FileManager.default.removeItem(at: folder)
}

@MainActor @Test func aSecretRequestOpensTheSheetAndTheBotGetsOnlyThePath() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    store.secretFolder = FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString)")
    defer { if let folder = store.secretFolder { try? FileManager.default.removeItem(at: folder) } }
    #expect(store.submitComposer(text: "provision QA"))
    try await waitUntil { await backend.streamCount == 1 }
    await finish(backend, secretReply)
    try await waitUntil { store.secretRequest != nil }
    let prompt = try #require(store.secretRequest)
    #expect(prompt.botID == bot.id && prompt.conversationID == bot.id && prompt.request.name == "openai-key")
    try await waitUntil { store.isIdle(bot) }
    #expect(store.provideSecret(prompt, value: "sk-test-value"))
    let path = try #require(store.secretFolder).appending(path: "openai-key").path
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:Secret `openai-key` is stored at \(path)") && !$0.contains("sk-test-value") } }
    #expect((try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) == "sk-test-value")
    #expect(!bot.messages.contains { $0.content.contains("sk-test-value") }, "the value never enters the chat")
}

@Test func swiftSecretWriterHandsOffToTheRealPythonProvisioningValidator() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "swarmhub-intake-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = SecretFileWriter.intakeFolder(home: home)
    let path = try SecretFileWriter.write("synthetic-swift-key", name: "qa-token", in: folder)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scripts = root.appending(path: "Resources/Skills/swarmhub-messages/scripts")
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-B", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import swarm_policy, swarm_intake; swarm_policy.policy=lambda: {'provisioner':['/bin/echo','FAKE']}; assert swarm_intake.is_intake_path(sys.argv[2]); argv=swarm_policy.provisioner_argv({'api_key':sys.argv[2]}); assert 'synthetic-swift-key' not in repr(argv)", scripts.path, path.path]
    process.environment = ["HOME": home.path, "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
    process.standardOutput = output; process.standardError = output
    try process.run(); let diagnostic = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(String(decoding: diagnostic, as: UTF8.self))")
}
