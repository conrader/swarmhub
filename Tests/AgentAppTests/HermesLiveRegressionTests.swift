import Foundation
import Testing
@testable import AgentApp

// Exact response bodies from LIVE-REPORT-1.md and sim/results/live-1/results.json.
// Kept inline so these regressions run without the untracked QA evidence directory.
private enum LiveFailureFixtures {
    static let native = #"""
event: run.started
data: {"user_message": {"role": "user", "content": "[QA-TEST] Reply with exactly QA-OK. Do not use tools."}, "runtime": {"provider": "", "model": "", "route_source": "global", "requested": {"provider": "", "model": ""}}, "session_id": "QA-LIVE1-20261019T083207-c7329d-native", "run_id": "run_b18c232d52924ed78a6ff4ebc769a6ed", "seq": 1, "ts": 1792398727.3701694}

event: message.started
data: {"message": {"id": "msg_4327b683a17f4c90a86399fa1694c99d", "role": "assistant"}, "session_id": "QA-LIVE1-20261019T083207-c7329d-native", "run_id": "run_b18c232d52924ed78a6ff4ebc769a6ed", "seq": 2, "ts": 1792398727.3701913}

event: assistant.completed
data: {"session_id": "QA-LIVE1-20261019T083207-c7329d-native", "message_id": "msg_4327b683a17f4c90a86399fa1694c99d", "content": "⚠️ I couldn't connect to the AI model service, so this message wasn't processed. Use /login to sign in again, or /model to pick a different model. If it keeps failing, run `hermes doctor` on the host.", "completed": false, "partial": false, "interrupted": false, "runtime": {"provider": "", "model": "", "route_source": "global", "requested": {"provider": "", "model": ""}}, "run_id": "run_b18c232d52924ed78a6ff4ebc769a6ed", "seq": 3, "ts": 1792398727.427055}

event: run.failed
data: {"session_id": "QA-LIVE1-20261019T083207-c7329d-native", "message_id": "msg_4327b683a17f4c90a86399fa1694c99d", "completed": false, "partial": false, "interrupted": false, "messages": [], "usage": {}, "runtime": {"provider": "", "model": "", "route_source": "global", "requested": {"provider": "", "model": ""}}, "run_id": "run_b18c232d52924ed78a6ff4ebc769a6ed", "seq": 4, "ts": 1792398727.427067}

event: done
data: {"session_id": "QA-LIVE1-20261019T083207-c7329d-native", "run_id": "run_b18c232d52924ed78a6ff4ebc769a6ed", "seq": 5, "ts": 1792398727.4271045}


"""#

    static let legacy = #"""
data: {"id": "chatcmpl-eb3d61352e0a4fbe81871a7be8907", "object": "chat.completion.chunk", "created": 1792398727, "model": "hermes-qa-swarmhub", "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": null}]}

data: {"id": "chatcmpl-eb3d61352e0a4fbe81871a7be8907", "object": "chat.completion.chunk", "created": 1792398727, "model": "hermes-qa-swarmhub", "choices": [{"index": 0, "delta": {"content": "\u26a0\ufe0f I couldn't connect to the AI model service, so this message wasn't processed. Use /login to sign in again, or /model to pick a different model. If it keeps failing, run `hermes doctor` on the host."}, "finish_reason": null}]}

data: {"id": "chatcmpl-eb3d61352e0a4fbe81871a7be8907", "object": "chat.completion.chunk", "created": 1792398727, "model": "hermes-qa-swarmhub", "choices": [{"index": 0, "delta": {}, "finish_reason": "error"}], "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}, "error": {"message": "No Codex credentials stored. Run `hermes auth add openai-codex --type oauth` to authenticate. Run `hermes model` to re-authenticate.", "type": "agent_error"}, "hermes": {"completed": false, "partial": false, "failed": true, "error": "No Codex credentials stored. Run `hermes auth add openai-codex --type oauth` to authenticate. Run `hermes model` to re-authenticate.", "error_code": "agent_error"}}

data: [DONE]


"""#

    static let badRequest = #"""
{"error": {"message": "Missing or invalid 'messages' field", "type": "invalid_request_error"}}
"""#

    static let unauthorized = #"""
{"error": {"message": "Invalid gateway API key (API_SERVER_KEY)", "type": "gateway_auth_error", "code": "gateway_auth_failed"}}
"""#

    static let serverError = #"""
500 Internal Server Error

Server got itself in trouble
"""#

    static let warning = "⚠️ I couldn't connect to the AI model service, so this message wasn't processed. Use /login to sign in again, or /model to pick a different model. If it keeps failing, run `hermes doctor` on the host."
    static let credentialError = "No Codex credentials stored. Run `hermes auth add openai-codex --type oauth` to authenticate. Run `hermes model` to re-authenticate."
}

private func liveFailureEvents(_ backend: HermesBackend) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in try await backend.send(.init(sessionID: "QA-live-regression", systemPrompt: "[QA-TEST] Do not use tools.", messages: [(role: "user", content: "[QA-TEST] Reply QA-OK. Do not use tools.")])) {
        events.append(event)
    }
    return events
}

private func failureReasons(_ events: [AgentEvent]) -> [String] {
    events.compactMap { if case .failed(let text) = $0 { text } else { nil } }
}

private func hasCompletion(_ events: [AgentEvent]) -> Bool {
    events.contains { if case .completed = $0 { true } else { false } }
}

@Test(arguments: [false, true]) func capturedProviderFailuresNeverEmitSuccess(legacy: Bool) async throws {
    let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { _, _ in
        .init(body: Data((legacy ? LiveFailureFixtures.legacy : LiveFailureFixtures.native).utf8))
    }
    let events = try await liveFailureEvents(backend)
    #expect(!hasCompletion(events))
    let expected = legacy ? LiveFailureFixtures.credentialError + " (agent_error)" : LiveFailureFixtures.warning
    #expect(failureReasons(events).last == expected)
    if !legacy {
        #expect(events.contains { if case .token(let text) = $0 { text == LiveFailureFixtures.warning } else { false } })
    }
    #expect(await backend.currentRunID(sessionID: "QA-live-regression") == nil)
}

@Test(arguments: [false, true]) @MainActor func capturedProviderFailuresLeaveAnIncompleteReplyAndDiagnostic(legacy: Bool) async throws {
    let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { _, _ in
        .init(body: Data((legacy ? LiveFailureFixtures.legacy : LiveFailureFixtures.native).utf8))
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.reconcileTiming.schedule = []
    let bot = Bot(name: "QA provider failure", backend: .hermes, hermesSessionID: "QA-live-regression")
    store.bots = [bot]; store.selectedBot = bot
    #expect(store.send(text: "[QA-TEST] Reply QA-OK. Do not use tools."))
    try await waitUntil { !store.anyTurnRunning }
    let reply = try #require(bot.messages.first { $0.role == .assistant })
    #expect(reply.turnState == .incomplete)
    #expect(reply.metadata[TurnKey.why] == "error")
    let expected = legacy ? LiveFailureFixtures.credentialError + " (agent_error)" : LiveFailureFixtures.warning
    #expect(store.errorMessage == expected)
    #expect(bot.messages.contains { $0.metadata[TurnKey.tone] == "warning" && $0.content.contains(expected) })
    #expect(AvatarReactions.shared.completions[bot.id] == nil)
}

@Test func legacyFailureCannotSeeAnotherGatewaysRunForTheSameSession() async throws {
    let (_, native) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in
        .sse([("assistant.delta", ["run_id": "native-run", "delta": "working"])], holdOpen: waitCeiling)
    }
    defer { native.session.invalidateAndCancel() }
    let stream = try await native.send(.init(sessionID: "QA-live-regression", systemPrompt: "QA", messages: [(role: "user", content: "QA")]))
    var iterator = stream.makeAsyncIterator()
    guard case .token("working")? = try await iterator.next() else { Issue.record("Expected a running native stream"); return }
    #expect(await native.currentRunID(sessionID: "QA-live-regression") == "native-run")
    var otherProfile = native
    otherProfile.profile = "other-profile"
    #expect(await otherProfile.currentRunID(sessionID: "QA-live-regression") == nil)

    let (_, legacy) = ChatParityServer.serve(features: ["session_chat_streaming": false]) { _, _ in
        .init(body: Data(LiveFailureFixtures.legacy.utf8))
    }
    #expect(await legacy.currentRunID(sessionID: "QA-live-regression") == nil)
    let events = try await liveFailureEvents(legacy)
    #expect(!hasCompletion(events) && !failureReasons(events).isEmpty)
    #expect(await legacy.currentRunID(sessionID: "QA-live-regression") == nil)
    #expect(await native.currentRunID(sessionID: "QA-live-regression") == "native-run", "Another connection's cleanup must preserve the active run")
}

@Test(arguments: [false, true]) @MainActor func explicitFailureWinsInEitherEventOrder(failureFirst: Bool) async throws {
    let backend = EndingBackend(.complete)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "QA event order", backend: .hermes)
    let reply = ChatMessage(role: .assistant, content: "")
    let events: [AgentEvent] = failureFirst ? [.failed("specific failure"), .completed] : [.completed, .failed("specific failure")]
    let stream = AsyncThrowingStream<AgentEvent, Error> { continuation in
        events.forEach { continuation.yield($0) }; continuation.finish()
    }
    let end = try await store.consumeTurn(stream, assistant: reply, bot: bot, sessionID: "QA-order", backend: backend) { _ in }
    #expect(TurnOutcome.classify(end) == .init(state: .incomplete, why: "error", reconcile: true, reason: "specific failure"))
}

@Test func unsuccessfulNativeResultsRemainFailedThroughTerminators() async throws {
    let flags: [[String: Any]] = [
        ["completed": false], ["completed": true, "failed": true],
        ["completed": true, "partial": true], ["completed": true, "interrupted": true]
    ]
    for terminal in ["assistant.completed", "run.completed"] {
        for flag in flags {
            let data = try JSONSerialization.data(withJSONObject: flag)
            let body = "event: \(terminal)\ndata: \(String(decoding: data, as: UTF8.self))\n\nevent: run.completed\ndata: {}\n\ndata: [DONE]\n\n"
            let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in .init(body: Data(body.utf8)) }
            let events = try await liveFailureEvents(backend)
            #expect(!hasCompletion(events))
            #expect(!failureReasons(events).isEmpty)
        }
    }
}

@Test func detailedRunFailureReplacesTheAssistantFallback() async throws {
    let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in
        .sse([
            ("assistant.completed", ["completed": false, "content": "provider warning"]),
            ("run.failed", ["error": ["message": "specific provider failure", "code": "agent_error"]]),
            ("done", [:])
        ])
    }
    let events = try await liveFailureEvents(backend)
    #expect(!hasCompletion(events))
    #expect(failureReasons(events).last == "specific provider failure (agent_error)")
}

@Test(arguments: ["assistant.completed", "run.completed"]) func successfulNativeFlagsStillComplete(terminal: String) async throws {
    let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in
        .sse([(terminal, ["completed": true, "partial": false, "interrupted": false, "failed": false])])
    }
    let events = try await liveFailureEvents(backend)
    #expect(hasCompletion(events) && failureReasons(events).isEmpty)
}

@Test func legacyHermesFailureMetadataPreservesItsDiagnosticWithoutAnErrorChoice() async throws {
    let (_, backend) = ChatParityServer.serve(features: [:]) { _, _ in
        .sse([("message", ["hermes": ["completed": false, "failed": true, "error": LiveFailureFixtures.credentialError, "error_code": "agent_error"]])])
    }
    #expect(failureReasons(try await liveFailureEvents(backend)).last == LiveFailureFixtures.credentialError + " (agent_error)")
}

@Test(arguments: [false, true]) func capturedHTTPStreamErrorsPreserveStatusAndDetail(legacy: Bool) async throws {
    let cases: [(Int, String, String)] = [
        (400, LiveFailureFixtures.badRequest, "Missing or invalid 'messages' field"),
        (401, LiveFailureFixtures.unauthorized, "Invalid gateway API key (API_SERVER_KEY) (gateway_auth_failed)"),
        (500, LiveFailureFixtures.serverError, LiveFailureFixtures.serverError)
    ]
    for (status, body, expected) in cases {
        let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { _, _ in
            .init(status: status, body: Data(body.utf8))
        }
        do {
            _ = try await liveFailureEvents(backend)
            Issue.record("Expected HTTP \(status)")
        } catch BackendError.http(let code, let message) {
            #expect(code == status)
            #expect(message == expected)
            let outcome = TurnOutcome.classify(.error(BackendError.http(code, message)))
            #expect(outcome.state == .notSent)
            #expect(outcome.reason?.contains(expected) == true)
            if status == 500 {
                #expect(outcome.ambiguous && outcome.round == .stopsRest(why: "timeout"))
            }
        }
    }
}

@Test(arguments: [false, true]) @MainActor func capturedHTTPStreamDiagnosticsReachTheUser(legacy: Bool) async throws {
    for (status, body, expected) in [
        (400, LiveFailureFixtures.badRequest, "Missing or invalid 'messages' field"),
        (401, LiveFailureFixtures.unauthorized, "gateway_auth_failed"),
        (500, LiveFailureFixtures.serverError, "Server got itself in trouble")
    ] {
        let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { _, _ in .init(status: status, body: Data(body.utf8)) }
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "QA HTTP failure", backend: .hermes, hermesSessionID: "QA-live-regression")
        store.bots = [bot]; store.selectedBot = bot
        #expect(store.send(text: "[QA-TEST] HTTP error handling"))
        try await waitUntil { !store.anyTurnRunning }
        #expect(bot.messages.first { $0.role == .assistant }?.turnState == .notSent)
        #expect(store.errorMessage?.contains("HTTP \(status)") == true)
        #expect(store.errorMessage?.contains(expected) == true)
        #expect(bot.messages.contains { $0.metadata[TurnKey.tone] == "warning" && $0.content.contains(expected) })
    }
}

@Test func HTTPStreamErrorBodiesAndDiagnosticsAreBoundedAndRedacted() async throws {
    let raw = "Echoed test-key API_SERVER_KEY=hidden-value " + String(repeating: "x", count: HermesBackend.errorBodyLimit * 2)
    let (_, backend) = ChatParityServer.serve(features: [:]) { _, _ in .init(status: 400, body: Data(raw.utf8)) }
    do {
        _ = try await liveFailureEvents(backend)
        Issue.record("Expected HTTP 400")
    } catch BackendError.http(let status, let message) {
        #expect(status == 400)
        #expect(!message.contains("test-key") && !message.contains("hidden-value"))
        #expect(message.contains("[key]") && message.count <= HermesBackend.diagnosticLimit)
    }
}

@Test func anUnclosedHTTPErrorBodyStillEndsAsAnHTTPError() async throws {
    let (_, original) = ChatParityServer.serve(features: [:]) { _, _ in .init(status: 500, body: Data(), holdOpen: waitCeiling) }
    var backend = original
    backend.timeouts.control = 0.1
    do {
        _ = try await liveFailureEvents(backend)
        Issue.record("Expected HTTP 500")
    } catch BackendError.http(let status, let message) {
        #expect(status == 500 && !message.isEmpty)
    }
}

@Test func legacySuccessfulChunksWithNullErrorsStillComplete() async throws {
    let (_, backend) = ChatParityServer.serve(features: [:]) { _, _ in
        .init(body: Data(#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}],"error":null}"#.utf8) + Data("\n\ndata: [DONE]\n\n".utf8))
    }
    let events = try await liveFailureEvents(backend)
    #expect(hasCompletion(events) && failureReasons(events).isEmpty)
}
