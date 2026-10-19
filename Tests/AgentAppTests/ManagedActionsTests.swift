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
    #expect(request.title == "Outbound action awaits the coordinator: draft-1" && request.hasKnownCommand)
    #expect(request.command == "scripts/swarmctl decide \(taskID) jarvis approve" && request.draft == "Hello Ada")
    #expect(request.summary == "Email Ada the release note · submitted by infra · \(taskID)")
    // Invalid task ids, kinds, gates and profiles are ignored or dropped; other ops are not approvals.
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"rm -rf\",\"kind\":\"outbound\",\"gate\":\"owner\"}\n```").isEmpty)
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"task.a\",\"kind\":\"shell\",\"gate\":\"owner\"}\n```").isEmpty)
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"task.a\",\"kind\":\"prod\",\"gate\":\"anyone\"}\n```").isEmpty)
    let odd = try #require(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"approval\",\"task\":\"task.a\",\"kind\":\"prod\",\"gate\":\"owner\",\"decider\":\"../x\",\"risks\":[\"prod\",\"bogus\"]}\n```").first)
    #expect(odd.decider == nil && odd.risks == ["prod"] && odd.draft == nil && odd.title == "Prod action awaits the owner: ")
    #expect(ManagedApproval.parse(in: "```swarmhub\n{\"op\":\"goal\",\"status\":\"done\"}\n```").isEmpty)
    #expect(ManagedApproval.profileName("jarvis\n") == nil && ManagedApproval.validTask(taskID + "\n") == nil)
    #expect(ManagedApproval.decisionTurn(task: "task.a", actor: "konrad", approved: false, title: "T").contains("`scripts/swarmctl decide task.a konrad deny`"))
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

@MainActor @Test func anApprovalFenceBecomesACardAndTheDecisionIsTheBotsOwnTurn() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    let reply = approvalReply.replacingOccurrences(of: "\"decider\":\"jarvis\"", with: "\"decider\":\"default\"")
    #expect(store.submitComposer(text: "send the draft"))
    try await waitUntil { await backend.streamCount == 1 }
    await finish(backend, reply)
    try await waitUntil { store.approvals.count == 1 }
    let card = try #require(store.approvals.first)
    #expect(card.isManaged && card.requestID == taskID && card.botID == bot.id && card.profile == "default" && card.draft == "Hello Ada")
    #expect(card.rule == "Managed action · gate coordinator" && card.hasKnownCommand)
    #expect(bot.approvalAudit.last?.outcome == .asked && bot.approvalAudit.last?.actionKind == "managed.outbound")
    // A redelivered fence never makes a second card.
    try await waitUntil { store.isIdle(bot) }
    #expect(store.submitComposer(text: "again"))
    try await waitUntil { await backend.streamCount == 2 }
    await finish(backend, reply)
    try await waitUntil { store.isIdle(bot) }
    #expect(store.approvals.count == 1)
    store.decide(card, approved: true)
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:[SwarmHub approval decision]") && $0.contains("`scripts/swarmctl decide \(taskID) default approve`") } }
    #expect(store.approvals.isEmpty && bot.messages.last { $0.role == .system }?.content.hasPrefix("Decision sent (approve):") == true)
    #expect(bot.approvalAudit.last?.outcome == .approved && bot.approvalAudit.last?.decidedBy == "user")
    await finish(backend, reply)
    try await waitUntil { store.isIdle(bot) }
    #expect(store.approvals.isEmpty, "redelivered cards cannot ask for a decision already sent")
}

@MainActor @Test func aMissingManagedDeciderNeverUsesTheSubmittingBotsIdentity() throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: approvalReply), bot: bot)
    let card = try #require(store.approvals.first)
    store.decide(card, approved: true)
    #expect(store.approvals.count == 1 && store.errorMessage?.contains("not connected") == true)
    #expect(!bot.messages.contains { $0.role == .user }, "no command is sent through the wrong gateway")
}

@MainActor @Test func managedApprovalsRouteToTheDeciderOnTheSubmittingBox() throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    let wrong = Bot(name: "Other Jarvis", backend: .hermes, hermesProfile: "jarvis")
    wrong.hermesBaseURL = "http://other-box.invalid:8742"
    let right = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "jarvis")
    store.bots = [bot, wrong, right]
    store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: approvalReply), bot: bot)
    #expect(try #require(store.approvals.first).botID == right.id)
    #expect(right.approvalAudit.count == 1 && wrong.approvalAudit.isEmpty)
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
