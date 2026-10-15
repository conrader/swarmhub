import Foundation
import Testing
@testable import AgentApp

// P16: a turn ends only with a terminal event; the real HermesBackend over synthetic SSE.

private func sseBody(_ events: [(String, [String: Any])], tail: String = "") -> Data {
    Data((events.map { name, payload in "event: \(name)\ndata: \(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)\n\n" }.joined() + tail).utf8)
}

private func drain(_ backend: HermesBackend, session: String = "s1") async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in try await backend.send(.init(sessionID: session, systemPrompt: "p", messages: [(role: "user", content: "question")])) { events.append(event) }
    return events
}

private func isCompleted(_ event: AgentEvent?) -> Bool { if case .completed? = event { true } else { false } }
private func isFailed(_ event: AgentEvent?) -> Bool { if case .failed? = event { true } else { false } }

@Test func eachTerminalEventEndsCleanly() async throws {
    for terminal in ["run.completed", "assistant.completed"] {
        let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in
            ChatParityServer.Reply(body: sseBody([("assistant.delta", ["delta": "hi"]), (terminal, ["run_id": "r"])]))
        }
        let events = try await drain(backend)
        #expect(events.contains(where: { isCompleted($0) }), "\(terminal)")
    }
}

@Test func endingsWithoutATerminalEventThrowADeliveredBreak() async throws {
    let bodies: [Data] = [
        sseBody([("assistant.delta", ["delta": "hi"]), ("done", [:])]),            // `done` alone proves nothing
        sseBody([("assistant.delta", ["delta": "hi"])]),                           // EOF with only deltas
        sseBody([("assistant.delta", ["delta": "hi"])], tail: ": keepalive\n\n"),  // EOF after a keepalive
    ]
    for body in bodies {
        let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in ChatParityServer.Reply(body: body) }
        do { _ = try await drain(backend); Issue.record("expected a break") }
        catch let error as StreamBreak { #expect(error.delivered && error.isEndOfStream) }
    }
}

@Test func theBoxsErrorThenDoneYieldsFailed() async throws {
    let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in
        ChatParityServer.Reply(body: sseBody([("assistant.delta", ["delta": "hi"]), ("error", ["message": "boom"]), ("done", [:])]))
    }
    let events = try await drain(backend)
    #expect(isFailed(events.last))
}

@Test func legacyEndings() async throws {
    let done = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n".utf8)) }
    #expect(isCompleted(try await drain(done.backend).last))
    let eof = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n".utf8)) }
    do { _ = try await drain(eof.backend); Issue.record("legacy EOF must break") } catch let error as StreamBreak { #expect(error.delivered) }
    let failed = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"error\"}]}\n\n".utf8)) }
    #expect(isFailed(try await drain(failed.backend).last))
    let hermesFailed = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: sseBody([("hermes.failed", ["error": "x"])])) }
    #expect(isFailed(try await drain(hermesFailed.backend).last))
}

@Test func failuresBeforeTheHeadersAreNotDeliveredAndHTTPStatusStaysHTTP() async throws {
    let (host, state, session) = SessionServer.serve()
    let backend = HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "k", session: session)
    state.with { $0.sessions["s1"] = []; $0.scripts = [.fail(.networkConnectionLost)] }
    do { _ = try await drain(backend); Issue.record("expected a break") }
    catch let error as StreamBreak { #expect(!error.delivered && (error.underlying as? URLError)?.code == .networkConnectionLost) }
    for status in [401, 403, 409, 429] {
        state.with { $0.scripts = [.status(status)] }
        do { _ = try await drain(backend); Issue.record("expected HTTP \(status)") }
        catch BackendError.http(let code, _) { #expect(code == status) }
    }
}

/// Answers capabilities; a chat POST gets no headers at all (stuck before the box).
private final class Silent: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url!.path.hasSuffix("capabilities") else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"features":{"session_chat_streaming":true}}"#.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func theOpenDeadlineFailsAStuckRequestAndAllowsForTheUpload() async throws {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [Silent.self]
    var silent = HermesBackend(baseURL: URL(string: "https://silent-\(UUID().uuidString.lowercased()).test/v1")!, apiKey: "k", session: URLSession(configuration: configuration))
    silent.timeouts.openDeadline = 0.2
    let started = ContinuousClock.now
    do { _ = try await drain(silent); Issue.record("expected the deadline") }
    catch let error as StreamBreak { #expect(!error.delivered && (error.underlying as? URLError)?.code == .timedOut) }
    #expect(ContinuousClock.now - started < .seconds(20))
    #expect(TurnOutcome.classify(.error(StreamBreak(delivered: false, underlying: URLError(.timedOut)))).why == "timeout")
    // The allowance grows with the body: 20 s + bytes ÷ 50 KB/s.
    #expect(HermesTimeouts().openDeadline(bodyBytes: 5_000_000) == 120)
    #expect(HermesTimeouts().openDeadline(bodyBytes: 0) == 20)
}

@Test func requestTimeoutsAreSetExplicitly() async throws {
    final class Recorder: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var seen: [String: TimeInterval] = [:]; static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self.seen["\(request.httpMethod ?? "") \(request.url!.path)"] = request.timeoutInterval }
            let path = request.url!.path
            let body: Data
            if path.hasSuffix("capabilities") { body = Data(#"{"features":{"session_chat_streaming":true,"run_steer":true}}"#.utf8) }
            else if path.hasSuffix("/chat/stream") { body = sseBody([("assistant.delta", ["run_id": "run-9", "delta": "x"]), ("run.completed", [:])]) }
            else { body = Data(#"{"session":{"id":"s1"},"accepted":true}"#.utf8) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [Recorder.self]
    var backend = HermesBackend(baseURL: URL(string: "https://timeouts.test/v1")!, apiKey: "k", session: URLSession(configuration: configuration))
    backend.timeouts = HermesTimeouts()  // the app's values (a test run's `.standard` is the hang ceiling)
    _ = try await backend.createSession(title: "t", systemPrompt: "p", id: "s1")
    _ = try await drain(backend)
    _ = try? await backend.jsonRequest(path: "api/jobs", method: "POST", body: [:])
    _ = try? await backend.requestStop(.serverRun("run-9"))
    let seen = Recorder.lock.withLock { Recorder.seen }
    #expect(seen["POST /api/sessions/s1/chat/stream"] == 90 && seen["POST /api/sessions"] == 30 && seen["GET /v1/capabilities"] == 30)
    #expect(seen["POST /api/jobs"] == 60 && seen["POST /v1/runs/run-9/stop"] == 8)
}

@Test func theProcessWideSessionHasNoCache() {
    let session = HermesURLSession.shared
    #expect(session === HermesURLSession.shared && session.configuration.urlCache == nil)
    #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData && !session.configuration.waitsForConnectivity)
}
