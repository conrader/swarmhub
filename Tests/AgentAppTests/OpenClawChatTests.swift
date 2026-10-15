import Foundation
import Testing
@testable import AgentApp

// P12 Part B: OpenClawBackend over the fake Gateway.

@MainActor func clawHub(_ fake: FakeGateway, keys: InMemoryKeyStore) -> OpenClawHub {
    OpenClawHub(status: OpenClawStatus(), keyStore: keys, makeTransport: fake.factory, clock: LoadTolerantGatewayClock(), jitter: { 0 })
}

@MainActor func clawBackend(_ fake: FakeGateway = FakeGateway(), mode: OpenClawBinding.SessionMode = .own) -> (OpenClawBackend, FakeGateway, OpenClawHub) {
    let (gateway, keys) = fakeGatewaySetup()
    let hub = clawHub(fake, keys: keys)
    return (OpenClawBackend(gateway: gateway, binding: .init(gatewayID: gateway.id, agentID: "agent-alpha", sessionMode: mode), hub: hub), fake, hub)
}

func chatEvent(_ state: String, run: String = "run-1", seq: Int, session: String = "agent:agent-alpha:s1", _ extra: [String: GatewayJSON] = [:]) -> GatewayJSON {
    var payload: [String: GatewayJSON] = ["runId": .string(run), "sessionKey": .string(session), "seq": .int(seq), "state": .string(state)]
    extra.forEach { payload[$0.key] = $0.value }
    return .object(payload)
}

func assistant(_ text: String) -> GatewayJSON { ["role": "assistant", "content": [["type": "text", "text": .string(text)]]] }

/// A `chat.send` that acks `runId` after pushing `before` on the socket (the ack/event race) and records nothing else.
func ackingSend(runId: String = "run-1", before: [GatewayJSON] = []) -> FakeGateway.Handler {
    { _, socket in
        before.forEach { socket.push(["type": "event", "event": "chat", "payload": $0]) }
        return .success(["runId": .string(runId), "status": "started"])
    }
}

func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [String] {
    var out: [String] = []
    for try await event in stream {
        switch event {
        case .token(let text): out.append("token:\(text)")
        case .replace(let text): out.append("replace:\(text)")
        case .status(let text): out.append("status:\(text)")
        case .tool(let tool): out.append("tool:\(tool.phase.rawValue):\(tool.name)")
        case .completed: out.append("completed")
        case .failed(let text): out.append("failed:\(text)")
        default: out.append("other")
        }
    }
    return out
}

@MainActor @Test func sendCarriesOnlyTheLastUserTextWithFreshKeysAndNoPersona() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["chat.send"] = ackingSend(before: [chatEvent("final", seq: 1, ["message": assistant("ok")])])
    let request = AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "SECRET PERSONA", messages: [("user", "first"), ("assistant", "a"), ("user", "second")])
    #expect(try await collect(backend.send(request)) == ["replace:ok", "completed"], "events before the ack are replayed once the run id is known")
    _ = try await collect(backend.send(request))
    let sends = fake.requestsFor("chat.send")
    #expect(sends.count == 2 && sends.allSatisfy { $0["message"] == "second" && $0["sessionKey"] == "agent:agent-alpha:s1" && $0["agentId"] == "agent-alpha" })
    #expect(sends[0]["idempotencyKey"] != sends[1]["idempotencyKey"] && sends.allSatisfy { $0["queueMode"] == nil })
    #expect(!sends.map(\.jsonText).joined().contains("SECRET PERSONA"), "persona and systemPrompt are sent nowhere")
    let schema = try ParamKeys()
    #expect(sends.flatMap { schema.problems("chat.send", $0) }.isEmpty)
}

@MainActor @Test func streamingFollowsTheRunAndIgnoresOtherSessionsAndRuns() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["chat.send"] = ackingSend()
    let stream = try await backend.send(AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "", messages: [("user", "hi")]))
    try await fake.requestLog.wait { $0.contains("chat.send") }
    fake.emit("chat", chatEvent("delta", seq: 1, ["message": assistant("Hel")]))
    fake.emit("chat", chatEvent("delta", seq: 1, ["message": assistant("dup")]))
    fake.emit("chat", chatEvent("delta", seq: 1, session: "agent:agent-alpha:other", ["message": assistant("not ours")]))
    fake.emit("chat", chatEvent("final", run: "run-steer", seq: 1, ["message": assistant("steer")]))
    fake.emit("agent", ["runId": "run-1", "seq": 1, "stream": "tool", "ts": 1, "data": ["phase": "start", "name": "exec"]])
    fake.emit("chat", chatEvent("delta", seq: 2, ["message": assistant("Hello")]))
    fake.emit("chat", chatEvent("final", seq: 3))
    #expect(try await collect(stream) == ["token:Hel", "tool:started:exec", "token:lo", "completed"])
}

@MainActor @Test func stopAbortsTheLedgersRunOrSaysThereIsNone() async throws {
    let (backend, fake, hub) = clawBackend()
    fake.handlers["chat.send"] = ackingSend(runId: "run-9")
    #expect(try await backend.stopTarget(sessionID: "agent:agent-alpha:s1") == .noActiveRun)
    let stream = try await backend.send(AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "", messages: [("user", "long task")]))
    try await waitFor { await hub.ledger.active(sessionKey: "agent:agent-alpha:s1") != nil }
    let target = try await backend.stopTarget(sessionID: "agent:agent-alpha:s1")
    let current = await backend.currentRunID(sessionID: "agent:agent-alpha:s1")
    #expect(target == .serverRun("run-9") && current == "run-9")
    #expect(try await backend.requestStop(target) == .requested)
    #expect(fake.requestsFor("chat.abort") == [["sessionKey": "agent:agent-alpha:s1", "agentId": "agent-alpha", "runId": "run-9"]])
    fake.emit("chat", chatEvent("aborted", run: "run-9", seq: 1))
    #expect(try await collect(stream) == ["completed"])
    try await waitFor { await hub.ledger.active(sessionKey: "agent:agent-alpha:s1") == nil }
}

@MainActor @Test func aGatewayWithoutChatAbortStopsLocally() async throws {
    let fake = FakeGateway(); fake.methods.removeAll { $0 == "chat.abort" }
    let (backend, _, hub) = clawBackend(fake)
    _ = try await backend.connected()
    await hub.ledger.start(.init(sessionKey: "agent:agent-alpha:s1", agentId: "agent-alpha", runId: "run-1"))
    #expect(try await backend.requestStop(.serverRun("run-1")) == .disconnectedLegacy && fake.requestsFor("chat.abort").isEmpty)
}

@MainActor @Test func steerUsesQueueModeAndARefusalOnlyHidesSteer() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["chat.send"] = ackingSend(runId: "run-steer")
    try await backend.steer(sessionID: "agent:agent-alpha:s1", text: "shorter please")
    let steer = try #require(fake.requestsFor("chat.send").first)
    #expect(steer["queueMode"] == "steer" && steer["message"] == "shorter please" && steer["idempotencyKey"]?.string?.isEmpty == false)
    #expect(try await backend.features().contains("run_steer"))
    fake.handlers["chat.send"] = { params, _ in params["queueMode"] == nil ? .success(["runId": "r"]) : .failure(GatewayError(code: "INVALID_REQUEST", message: "queueMode")) }
    await #expect(throws: BackendError.self) { try await backend.steer(sessionID: "agent:agent-alpha:s1", text: "again") }
    let flags = try await backend.features()
    #expect(!flags.contains("run_steer") && flags.contains("session_chat_streaming") && flags.contains("session_fork"))

    let readOnly = FakeGateway(); readOnly.grantedScopes = ["operator.read"]
    let (viewer, _, _) = clawBackend(readOnly)
    let refusal = await #expect(throws: BackendError.self) { try await viewer.steer(sessionID: "agent:agent-alpha:s1", text: "x") }
    #expect(refusal?.localizedDescription == "This Mac lacks operator.write on the Gateway.")
}

@MainActor @Test func historyMapsVisibleUserAndAssistantRows() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["chat.history"] = { _, _ in .success(["messages": [
        ["role": "user", "content": [["type": "text", "text": "look"], ["type": "image", "mimeType": "image/png", "fileName": "cat.png"]], "timestamp": "2026-10-13T12:00:00.000Z"],
        ["role": "assistant", "content": [["type": "text", "text": "[[reply_to_current]] A cat."]], "timestamp": 1_760_356_800_000],
        ["role": "toolResult", "content": "exit 0"], ["role": "system", "content": "compacted"],
        ["role": "assistant", "content": "NO_REPLY"],
    ], "sessionInfo": ["hasActiveRun": false, "activeRunIds": []]]) }
    let rows = try await backend.loadMessages(sessionID: "agent:agent-alpha:s1")
    #expect(rows.map(\.role) == ["user", "assistant"] && rows.map(\.content) == ["look\n[Image: cat.png]", "A cat."])
    #expect(rows[0].createdAt == ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z") && rows[1].createdAt == Date(timeIntervalSince1970: 1_760_356_800))
    #expect(fake.requestsFor("chat.history") == [["sessionKey": "agent:agent-alpha:s1", "agentId": "agent-alpha", "limit": 200, "maxChars": 20000]])
}

@MainActor @Test func aDroppedLinkResumesFromHistoryWithoutResending() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["chat.send"] = ackingSend(before: [chatEvent("delta", seq: 1, ["message": assistant("Part")])])
    fake.handlers["chat.history"] = { _, socket in
        Task { try? await Task.sleep(for: .milliseconds(20)); socket.push(["type": "event", "event": "chat", "payload": chatEvent("final", seq: 5, ["message": assistant("Partial answer, done")])]) }
        return .success(["messages": [], "sessionInfo": ["hasActiveRun": true, "activeRunIds": ["run-1"]], "inFlightRun": ["runId": "run-1", "text": "Partial answer"]])
    }
    let stream = try await backend.send(AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "", messages: [("user", "q")]))
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next().map { if case .token(let t) = $0 { t } else { "?" } } == "Part")
    fake.lastSocket?.drop()
    var rest: [String] = []
    while let event = try await iterator.next() { if case .token(let t) = event { rest.append("token:\(t)") } else if case .replace(let t) = event { rest.append("replace:\(t)") } else if case .completed = event { rest.append("completed") } }
    #expect(rest == ["token:ial answer", "replace:Partial answer, done", "completed"], "in-flight text first, then the final snapshot")
    #expect(fake.requestsFor("chat.send").count == 1, "never resent by hand")
}

@MainActor @Test func aRunThatFinishedWhileAwayTakesTheFinalMessageAndAGoneRunFailsPlainly() async throws {
    let (backend, fake, hub) = clawBackend()
    fake.handlers["chat.send"] = ackingSend()
    fake.handlers["chat.history"] = { _, _ in .success(["messages": [["role": "user", "content": "q"], ["role": "assistant", "content": "All done."]], "sessionInfo": ["hasActiveRun": false, "activeRunIds": []]]) }
    let stream = try await backend.send(AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "", messages: [("user", "q")]))
    // The link drops after the client has the ack's run id (a drop before the ack is a failed send, not this case).
    try await waitUntil { await hub.ledger.run(id: "run-1") != nil }
    fake.lastSocket?.drop()
    #expect(try await collect(stream) == ["replace:All done.", "completed"])

    fake.handlers["chat.history"] = { _, _ in .success(["messages": [["role": "user", "content": "q"]], "sessionInfo": ["hasActiveRun": false]]) }
    fake.handlers["chat.send"] = ackingSend(runId: "run-2")
    let lost = try await backend.send(AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "", messages: [("user", "q")]))
    try await waitUntil { await hub.ledger.run(id: "run-2") != nil }
    fake.lastSocket?.drop()
    let failure = await #expect(throws: BackendError.self) { _ = try await collect(lost) }
    #expect(failure?.localizedDescription == OpenClawBackend.lostRun)
}

@MainActor @Test func createSessionNamesTheKeyAndRetriesWithoutOptionalParameters() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["sessions.create"] = { params, _ in .success(["ok": true, "key": params["key"] ?? .null]) }
    let key = try await backend.createSession(title: "Ada", systemPrompt: "IGNORED", id: "agentapp_ABC_def")
    #expect(key == "agent:agent-alpha:agentapp-abc-def")
    #expect(fake.requestsFor("sessions.create") == [["agentId": "agent-alpha", "key": "agent:agent-alpha:agentapp-abc-def", "displayName": "SwarmHub · Ada", "idempotencyKey": "agent:agent-alpha:agentapp-abc-def"]])
    fake.handlers["sessions.create"] = { params, _ in params["displayName"] == nil ? .success(["ok": true, "key": params["key"] ?? .null]) : .failure(GatewayError(code: "INVALID_REQUEST", message: "displayName")) }
    #expect(try await backend.createSession(title: "Ada", systemPrompt: "", id: "x2") == "agent:agent-alpha:x2")
    #expect(fake.requestsFor("sessions.create").last == ["agentId": "agent-alpha", "key": "agent:agent-alpha:x2"])
    let schema = try ParamKeys()
    #expect(fake.requestsFor("sessions.create").flatMap { schema.problems("sessions.create", $0) }.isEmpty)

    let (shared, sharedFake, _) = clawBackend(mode: .main)
    #expect(try await shared.createSession(title: "Ada", systemPrompt: "", id: "x") == "agent:agent-alpha:main" && sharedFake.requestsFor("sessions.create").isEmpty)
}

@MainActor @Test func featuresNeverConnectAndTestListsAgents() async throws {
    let (backend, fake, _) = clawBackend()
    #expect(try await backend.features().isEmpty && fake.lastSocket == nil, "reading features does not connect")
    #expect(try await backend.testConnection() == "OpenClaw 2026.10.3 · protocol 4 · scopes operator.read, operator.write, operator.approvals · 2 agents · attachments up to 20 MB")
    #expect(try await backend.features() == ["session_chat_streaming", "run_steer", "session_fork"])
}

@MainActor @Test func theModelCatalogGroupsTheGatewaysListByProvider() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["models.list"] = { _, _ in .success(["models": [
        ["id": "drift-a", "name": "Drift A", "provider": "drift-cloud"], ["id": "ember-one", "name": "Ember", "provider": "ember-labs", "available": false, "unavailableReason": "auth_missing"],
    ]]) }
    fake.handlers["agents.list"] = { _, _ in .success(["defaultId": "agent-alpha", "mainKey": "main", "scope": "global", "agents": [["id": "agent-alpha", "model": ["primary": "ember-labs/ember-one"]]]]) }
    await #expect(throws: BackendError.self) { try await backend.modelCatalog(sessionID: nil) }
    _ = try await backend.connected()
    let catalog = try await backend.modelCatalog(sessionID: nil)
    #expect(catalog.suppliers.map(\.slug) == ["ember-labs", "drift-cloud"] && catalog.defaultSupplier == "ember-labs" && catalog.agentDefault?.model == "ember-labs/ember-one")
    #expect(catalog.suppliers[0].reason(for: "ember-one") == "Not available on the Gateway now (auth missing)." && catalog.pinning == .none)
    #expect(catalog.place == "OpenClaw Gateway Test Gateway" && catalog.detail == "Agent agent-alpha" && backend.catalogScope.hasSuffix("|agent-alpha"))
    #expect(fake.requestsFor("models.list") == [["agentId": "agent-alpha"]])
}

@MainActor @Test func aRejectedSendDoesNotDisableChatForTheLink() async throws {
    let (backend, fake, _) = clawBackend()
    fake.handlers["chat.send"] = { _, _ in .failure(GatewayError(code: "INVALID_REQUEST", message: "attachment too large")) }
    await #expect(throws: BackendError.self) { _ = try await collect(backend.send(AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "", messages: [("user", "x")]))) }
    #expect(try await backend.features() == ["session_chat_streaming", "run_steer", "session_fork"], "only optional parameters mark a feature")
}

@MainActor @Test func stopBeforeTheAckStillAbortsTheRun() async throws {
    let fake = FakeGateway(); fake.silentMethods = ["chat.send"]
    let (backend, _, _) = clawBackend(fake)
    let stream = try await backend.send(AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: "", messages: [("user", "x")]))
    let consumer = Task { try await collect(stream) }
    try await fake.requestLog.wait { $0.contains("chat.send") }
    consumer.cancel()
    let socket = try #require(fake.lastSocket)
    let ids = socket.sentFrames.compactMap { text -> String? in
        guard case .request(let id, "chat.send", _)? = GatewayFrame.decode(text) else { return nil }; return id }
    let sendID = try #require(ids.first)
    fake.respond(to: sendID, on: socket, payload: ["runId": "run-late"])
    try await fake.requestLog.wait { $0.contains("chat.abort") }
    #expect(fake.requestsFor("chat.abort") == [["sessionKey": "agent:agent-alpha:s1", "agentId": "agent-alpha", "runId": "run-late"]])
}
