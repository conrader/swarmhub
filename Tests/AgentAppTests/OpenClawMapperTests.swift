import Foundation
import Testing
@testable import AgentApp

// P12 Part B: the pure stream mapper, visible-text rules and the capabilities table.

private let key = "agent:agent-alpha:agentapp-1"

private func chat(_ state: String, run: String = "run-1", seq: Int, session: String = key, _ extra: [String: GatewayJSON] = [:]) -> GatewayEvent {
    var payload: [String: GatewayJSON] = ["runId": .string(run), "sessionKey": .string(session), "seq": .int(seq), "state": .string(state)]
    extra.forEach { payload[$0.key] = $0.value }
    return GatewayEvent(event: "chat", payload: .object(payload), seq: nil)
}

private func snapshot(_ text: String) -> GatewayJSON { ["role": "assistant", "content": [["type": "text", "text": .string(text)], ["type": "thinking", "thinking": "hidden"]]] }

private func render(_ events: [AgentEvent]) -> [String] {
    events.map { event in
        switch event {
        case .token(let text): "token:\(text)"
        case .replace(let text): "replace:\(text)"
        case .status(let text): "status:\(text)"
        case .tool(let tool): "tool:\(tool.phase.rawValue):\(tool.name)"
        case .completed: "completed"
        case .failed(let text): "failed:\(text)"
        case .approval: "approval"
        case .subAgent: "subagent"
        case .steer: "steer"
        case .hiddenTokens(let count): "hidden:\(count)"
        }
    }
}

private func run(_ events: [GatewayEvent], primary: String = "run-1", ignore: [String] = []) -> [String] {
    var mapper = OpenClawRunMapper(sessionKey: key); mapper.setPrimary(primary); ignore.forEach { mapper.ignore($0) }
    return render(events.flatMap { mapper.map($0) })
}

@Test func snapshotsExtendAsTokensAndReplaceWhenTheyDiverge() {
    #expect(run([chat("delta", seq: 1, ["deltaText": "Hel", "message": snapshot("Hel")]),
                 chat("delta", seq: 2, ["deltaText": "lo", "message": snapshot("Hello")]),
                 chat("delta", seq: 3, ["deltaText": "", "message": snapshot("Help")]),
                 chat("final", seq: 4, ["message": snapshot("Help!")])])
            == ["token:Hel", "token:lo", "replace:Help", "replace:Help!", "completed"])
}

@Test func replaceAndBareAppendsFollowTheReferenceMergeRules() {
    #expect(run([chat("delta", seq: 1, ["deltaText": "ignored: no baseline"]),
                 chat("delta", seq: 2, ["deltaText": "Start", "replace": true]),
                 chat("delta", seq: 3, ["deltaText": " more"]),
                 chat("delta", seq: 4, ["deltaText": "Fresh", "replace": true]),
                 chat("final", seq: 5)])
            == ["replace:Start", "token: more", "replace:Fresh", "completed"])
}

@Test func duplicateSeqOtherRunsAndOtherSessionsAreIgnored() {
    #expect(run([chat("delta", seq: 1, ["message": snapshot("A")]),
                 chat("delta", seq: 1, ["message": snapshot("AAAA")]),
                 chat("delta", seq: 2, session: "agent:agent-alpha:other", ["message": snapshot("other session")]),
                 chat("final", run: "steer-run", seq: 9, ["message": snapshot("steer reply")]),
                 chat("delta", seq: 3, ["message": snapshot("AB")]),
                 chat("final", seq: 4)], ignore: ["steer-run"])
            == ["token:A", "token:B", "completed"])
}

@Test func endsAbortsErrorsAndStatusesInPlainWords() {
    #expect(run([chat("aborted", seq: 1)]) == ["completed"])
    #expect(run([chat("error", seq: 1, ["errorKind": "rate_limit", "errorMessage": "429 from provider"])]) == ["failed:The model provider is rate limiting this agent. (429 from provider)"])
    #expect(run([chat("error", seq: 1, ["errorKind": "context_length"])]) == ["failed:The conversation is too long for the model's context."])
    #expect(run([chat("error", seq: 1, ["errorKind": "refusal"])]) == ["failed:The model declined to answer."])
    #expect(run([chat("error", seq: 1, ["errorKind": "timeout"])]) == ["failed:The model took too long to answer."])
    #expect(run([chat("error", seq: 1)]) == ["failed:The OpenClaw run failed."])
    #expect(run([chat("status", seq: 1, ["phase": "starting_model"]), chat("status", seq: 2, ["retry": ["attempt": 1, "maxAttempts": 3, "reason": "rate_limit"]])])
            == ["status:Starting the model…", "status:Rate limited; retrying (1 of 3)…"])
    let tool = GatewayEvent(event: "agent", payload: ["runId": "run-1", "seq": 1, "stream": "tool", "ts": 1, "data": ["phase": "start", "name": "exec"]], seq: nil)
    let otherTool = GatewayEvent(event: "agent", payload: ["runId": "run-2", "seq": 1, "stream": "tool", "ts": 1, "data": ["phase": "start", "name": "browser"]], seq: nil)
    #expect(run([tool, otherTool]) == ["tool:started:exec"])
    #expect(run([chat("final", seq: 1), chat("delta", seq: 2, ["message": snapshot("late")])]) == ["completed"], "nothing after the end")
}

@Test func directivesAreStrippedAndNoReplyIsEmpty() {
    #expect(OpenClawText.clean("[[reply_to_current]] Hi there") == "Hi there")
    #expect(OpenClawText.clean("Sure [[reply_to: msg-42]]done[[audio_as_voice]]") == "Sure done")
    #expect(OpenClawText.clean("NO_REPLY") == "" && OpenClawText.clean("  no_reply\n") == "" && OpenClawText.clean("NO_REPLY please") == "NO_REPLY please")
    #expect(OpenClawText.clean("Partial [[reply_to") == "Partial ", "an unfinished directive is held back while streaming")
    #expect(run([chat("delta", seq: 1, ["message": snapshot("[[reply_to_current]] Hi")]), chat("final", seq: 2, ["message": snapshot("NO_REPLY")])])
            == ["token:Hi", "replace:", "completed"])
    #expect(OpenClawText.visible(["role": "assistant", "content": "plain string"]) == "plain string")
}

@Test func aSteerJoiningThePrimaryRunIsNotIgnored() {
    var mapper = OpenClawRunMapper(sessionKey: key); mapper.setPrimary("run-1"); mapper.ignore("run-1")
    #expect(mapper.ignoredRuns.isEmpty && render(mapper.map(chat("final", seq: 1))) == ["completed"])
}

// MARK: Capabilities

private func summary(methods: [String], scopes: [String]) -> GatewaySummary {
    var value = GatewaySummary(protocolVersion: 4, serverVersion: "2026.10.3"); value.methods = Set(methods); value.scopes = scopes; return value
}

private let allMethods = ["agents.list", "sessions.create", "sessions.list", "chat.send", "chat.abort", "chat.history", "exec.approval.list", "exec.approval.resolve", "models.list"]

@Test(arguments: [
    (allMethods, OpenClawClient.scopes, Set(OpenClawFeature.allCases), Set(["session_chat_streaming", "run_steer", "session_fork"])),
    (allMethods, ["operator.read"], [.agents, .history, .sessions, .models], Set<String>()),
    (allMethods.filter { $0 != "chat.abort" }, OpenClawClient.scopes, Set(OpenClawFeature.allCases).subtracting([.stop]), Set(["session_chat_streaming", "run_steer", "session_fork"])),
    (["chat.send", "chat.history"], ["operator.read", "operator.write"], [.chat, .steer, .attachments, .history], Set(["session_chat_streaming", "run_steer"])),
    (allMethods, ["operator.admin"], Set(OpenClawFeature.allCases), Set(["session_chat_streaming", "run_steer", "session_fork"])),
] as [([String], [String], Set<OpenClawFeature>, Set<String>)])
func capabilitiesComeFromListedMethodsAndHeldScopes(methods: [String], scopes: [String], available: Set<OpenClawFeature>, flags: Set<String>) {
    let caps = OpenClawCapabilities(summary: summary(methods: methods, scopes: scopes))
    #expect(Set(OpenClawFeature.allCases.filter(caps.isAvailable)) == available)
    #expect(caps.hermesFlags == flags)
}

@Test func reasonsNameTheMethodOrScopeAndRuntimeMarksAreNarrow() async {
    var caps = OpenClawCapabilities(summary: summary(methods: allMethods.filter { $0 != "chat.abort" }, scopes: ["operator.read", "operator.write"]))
    #expect(caps.reason(.stop) == "This Gateway does not offer chat.abort.")
    #expect(caps.reason(.approvals) == "This Mac lacks operator.approvals on the Gateway.")
    caps.unsupported = [.steer]
    #expect(!caps.isAvailable(.steer) && caps.isAvailable(.chat) && caps.hermesFlags == ["session_chat_streaming", "session_fork"], "a rejected steer hides only Steer")
    let marks = OpenClawRuntimeMarks()
    await marks.mark(.threads, gatewayID: "gw", connId: "c1")
    #expect(await marks.unsupported(gatewayID: "gw", connId: "c1") == [.threads])
    #expect(await marks.unsupported(gatewayID: "gw", connId: "c2").isEmpty, "a new connection starts clean")
}

@Test func attachmentsAreRawBase64AndCheckedAgainstTheGatewayLimits() throws {
    var limits = summary(methods: allMethods, scopes: OpenClawClient.scopes); limits.maxImageBytes = 8; limits.maxPayload = 400
    let small = "data:image/png;base64," + Data("1234".utf8).base64EncodedString()
    let encoded = try OpenClawAttachments.encode([small], summary: limits)
    #expect(encoded == [["type": "image", "mimeType": "image/png", "fileName": "image-1.png", "content": .string(Data("1234".utf8).base64EncodedString())]])
    let big = "data:image/jpeg;base64," + Data(repeating: 1, count: 9).base64EncodedString()
    #expect(throws: OpenClawAttachments.Refusal.self) { try OpenClawAttachments.encode([big], summary: limits) }
    #expect(throws: OpenClawAttachments.Refusal.self) { try OpenClawAttachments.checkFrame(["message": .string(String(repeating: "x", count: 500))], summary: limits) }
    #expect(throws: OpenClawAttachments.Refusal.self) { try OpenClawAttachments.encode(["https://example.invalid/x.png"], summary: limits) }
}
