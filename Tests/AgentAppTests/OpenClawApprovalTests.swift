import Foundation
import Testing
@testable import AgentApp

// P12 Part C: Gateway approvals end to end over the fake (synthetic commands only).

private func approvalPayload(_ id: String, command: String = "cat /tmp/x", session: String? = "agent:agent-alpha:s1", agent: String = "agent-alpha",
                             run: String? = "run-1", expires: Int? = nil) -> GatewayJSON {
    var request: [String: GatewayJSON] = ["command": .string(command), "cwd": "/srv/work", "host": "gateway", "agentId": .string(agent)]
    if let session { request["sessionKey"] = .string(session) }
    if let run { request["runId"] = .string(run) }
    var payload: [String: GatewayJSON] = ["id": .string(id), "request": .object(request), "createdAtMs": .int(1_760_000_000_000)]
    if let expires { payload["expiresAtMs"] = .int(expires) }
    return .object(payload)
}

/// A connected store whose OpenClaw bot owns session `s1`.
@MainActor private func connectedStore(_ fake: FakeGateway = FakeGateway(), mode: ApprovalMode = .ask) async throws -> (AppStore, Bot, OpenClawGateway) {
    let (store, bot, gateway, _) = clawStore(fake)
    bot.hermesSessionID = "agent:agent-alpha:s1"; bot.approvalMode = mode
    bot.approvalRules = [.init(name: "Allow reads", actionPattern: "command", commandPattern: "cat *", outcome: .allow)]
    _ = try await store.openClawHub.connection(for: gateway)
    try await fake.requestLog.wait { $0.contains("exec.approval.list") }
    return (store, bot, gateway)
}

@MainActor @Test func approvalsMapFromTheGatewaysShape() {
    let event = GatewayApproval(gatewayID: "gw", json: approvalPayload("ap-1", expires: 1_760_000_060_000))
    #expect(event == GatewayApproval(gatewayID: "gw", id: "ap-1", command: "cat /tmp/x", cwd: "/srv/work", host: "gateway", agentId: "agent-alpha",
                                     sessionKey: "agent:agent-alpha:s1", runId: "run-1", expiresAtMs: 1_760_000_060_000))
    let planned = GatewayApproval(gatewayID: "gw", json: ["id": "ap-2", "request": ["systemRunPlan": ["argv": ["ls"], "cwd": "/a", "commandText": "ls -la", "agentId": "agent-alpha", "sessionKey": "agent:agent-alpha:s1"]]])
    #expect(planned?.command == "ls -la" && planned?.cwd == "/a" && planned?.sessionKey == "agent:agent-alpha:s1")
    #expect(GatewayApproval(gatewayID: "gw", json: ["request": ["command": "x"]]) == nil, "no id, no approval")
    let bot = Bot(name: "Alpha", backend: .openClaw)
    let request = AppStore.approvalRequest(event!, bot: bot, ownSession: true)
    #expect(request.requestID == "ap-1" && request.command == "cat /tmp/x" && request.summary == "cat /tmp/x · in /srv/work · on gateway")
    #expect(request.sessionID == "agent:agent-alpha:s1" && request.botID == bot.id && request.title == "Run a command on gateway")
    #expect(AppStore.approvalRequest(event!, bot: bot, ownSession: false).title.hasSuffix("(from another session)"))
    #expect(OpenClawBackend.decision(approved: true) == "allow-once" && OpenClawBackend.decision(approved: false) == "deny")
}

@MainActor @Test func approvalsForARunStartedHereFollowTheBotsRules() async throws {
    let fake = FakeGateway()
    let (store, bot, _) = try await connectedStore(fake, mode: .rules)
    await store.openClawHub.ledger.start(.init(sessionKey: "agent:agent-alpha:s1", agentId: "agent-alpha", runId: "run-1"))
    fake.emit("exec.approval.requested", approvalPayload("ap-own"))
    try await fake.requestLog.wait { $0.contains("exec.approval.resolve") }
    #expect(fake.requestsFor("exec.approval.resolve") == [["id": "ap-own", "decision": "allow-once"]])
    try await waitUntil { bot.approvalAudit.contains { $0.outcome == .approved && $0.decidedBy.hasPrefix("rule:") } }
    #expect(store.approvals.isEmpty)
}

@MainActor @Test func everyOtherApprovalIsAskOnlyEvenUnderRules() async throws {
    let fake = FakeGateway()
    let (store, bot, _) = try await connectedStore(fake, mode: .rules)
    fake.emit("exec.approval.requested", approvalPayload("ap-cron", session: "agent:agent-alpha:cron:nightly", run: "cron-run"))
    fake.emit("exec.approval.requested", approvalPayload("ap-other", run: "someone-elses-run"))
    fake.emit("exec.approval.requested", approvalPayload("ap-stranger", session: "agent:agent-zeta:s9", agent: "agent-zeta"))
    try await waitUntil { store.approvals.count == 2 }
    #expect(Set(store.approvals.compactMap(\.requestID)) == ["ap-cron", "ap-other"], "an agent without a bot is left for other clients")
    #expect(store.approvals.first { $0.requestID == "ap-cron" }?.title.hasSuffix("(from another session)") == true)
    #expect(store.approvals.allSatisfy { $0.botID == bot.id } && fake.requestsFor("exec.approval.resolve").isEmpty, "never auto-approved")
    #expect(bot.approvalAudit.contains { $0.reason == "Not started in SwarmHub: ask-only, never automatic." })
}

@MainActor @Test func theUserDecidesWithAllowOnceOrDenyOnly() async throws {
    let fake = FakeGateway()
    let (store, _, _) = try await connectedStore(fake)
    fake.emit("exec.approval.requested", approvalPayload("ap-1", run: nil))
    fake.emit("exec.approval.requested", approvalPayload("ap-2", run: nil))
    try await waitUntil { store.approvals.count == 2 }
    store.decide(try #require(store.approvals.first { $0.requestID == "ap-1" }), approved: true)
    store.decide(try #require(store.approvals.first { $0.requestID == "ap-2" }), approved: false)
    try await fake.requestLog.wait { $0.filter { $0 == "exec.approval.resolve" }.count == 2 }
    #expect(Set(fake.requestsFor("exec.approval.resolve")) == [["id": "ap-1", "decision": "allow-once"], ["id": "ap-2", "decision": "deny"]])
    #expect(!fake.requestsFor("exec.approval.resolve").map(\.jsonText).joined().contains("allow-always"))
    try await waitUntil { store.approvals.isEmpty }
    fake.emit("exec.approval.requested", approvalPayload("ap-3", command: " ", run: nil))
    try await waitUntil { store.approvals.count == 1 }
    store.decide(store.approvals[0], approved: true)
    #expect(store.errorMessage == "Cannot approve an OpenClaw request without command text." && store.approvals.count == 1, "no command text, no approve")
}

@MainActor @Test func resolvedElsewhereOrExpiredRemovesTheCard() async throws {
    let fake = FakeGateway()
    let (store, _, _) = try await connectedStore(fake)
    fake.emit("exec.approval.requested", approvalPayload("ap-1", run: nil))
    try await waitUntil { store.approvals.count == 1 }
    fake.emit("exec.approval.resolved", ["id": "ap-1", "decision": "allow-once"])
    try await waitUntil { store.approvals.isEmpty }
    let now = Int(Date().timeIntervalSince1970 * 1000)
    fake.emit("exec.approval.requested", approvalPayload("ap-old", run: nil, expires: now - 1_000))
    fake.emit("exec.approval.requested", approvalPayload("ap-soon", run: nil, expires: now + 300))
    try await waitUntil { store.approvals.contains { $0.requestID == "ap-soon" } }
    #expect(!store.approvals.contains { $0.requestID == "ap-old" }, "already expired: never shown")
    try await waitUntil { store.approvals.isEmpty }
}

@MainActor @Test func theBackfillIsReconciledByIDAndNeverResurrectsAResolvedApproval() async throws {
    let fake = FakeGateway()
    fake.handlers["exec.approval.list"] = { _, socket in
        socket.push(["type": "event", "event": "exec.approval.resolved", "payload": ["id": "ap-a"]])
        return .success(["approvals": [approvalPayload("ap-a", run: nil), approvalPayload("ap-b", run: nil)]])
    }
    let (store, _, _) = try await connectedStore(fake)
    try await waitUntil { store.approvals.contains { $0.requestID == "ap-b" } }
    fake.emit("exec.approval.requested", approvalPayload("ap-b", run: nil))
    try await Task.sleep(for: .milliseconds(50))
    #expect(store.approvals.compactMap(\.requestID) == ["ap-b"], "A stays resolved; B appears once")
}

// MARK: Schema conformance of every request

@MainActor @Test func everyRequestSwarmHubBuildsUsesOnlySchemaKeys() async throws {
    let fake = FakeGateway()
    fake.handlers["sessions.create"] = echoCreate()
    fake.handlers["models.list"] = { _, _ in .success(["models": []]) }
    let (backend, _, hub) = clawBackend(fake)
    let key = try await backend.createSession(title: "Ada", systemPrompt: "", id: "agentapp_x")
    fake.handlers["chat.send"] = ackingSend(before: [chatEvent("final", seq: 1, session: key, ["message": assistant("ok")])])
    _ = try await collect(backend.send(AgentRequest(sessionID: key, systemPrompt: "", messages: [("user", "hi")], images: ["data:image/png;base64,MTIzNA=="])))
    try await backend.steer(sessionID: key, text: "steer")
    await hub.ledger.start(.init(sessionKey: key, agentId: "agent-alpha", runId: "run-x"))
    _ = try await backend.requestStop(.serverRun("run-x"))
    _ = try await backend.loadMessages(sessionID: key)
    _ = try await backend.listSessions()
    _ = try await backend.forkSession(sessionID: key, id: "agentapp_thread_y")
    _ = try await backend.modelCatalog(sessionID: nil)
    try await backend.resolveApproval(ApprovalRequest(id: UUID(), title: "t", summary: "s", draft: nil, command: "ls", requestID: "ap-1"), approved: true)
    let schema = try ParamKeys()
    for method in ["sessions.create", "chat.send", "chat.abort", "chat.history", "sessions.list", "models.list", "agents.list", "exec.approval.resolve", "exec.approval.list"] {
        let sent = fake.requestsFor(method)
        #expect(!sent.isEmpty, "\(method) was exercised")
        for params in sent { #expect(schema.problems(method, params).isEmpty, "\(method): \(schema.problems(method, params))") }
    }
    #expect(fake.requestsFor("exec.approval.list").allSatisfy { $0 == [:] }, "no params definition in the schema: send none")
    #expect(schema.entry("chat.send")?.closed == true && schema.raw["sha256"]?.string?.hasPrefix("b7ab8a51") == true)
}
