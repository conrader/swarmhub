import Foundation
import Testing
@testable import AgentApp

/// A synthetic detachable run server; no real Hermes turns or process signals.
private final class RecoveryServer: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var data = Data()
        var error: URLError.Code? = nil
        var hold = false
        static func json(_ object: [String: Any], status: Int = 200) -> Self {
            .init(status: status, data: try! JSONSerialization.data(withJSONObject: object))
        }
        static func events(_ rows: [[String: Any]], hold: Bool = false) -> Self {
            .init(data: Data(rows.map { "data: \(String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self))\n\n" }.joined().utf8), hold: hold)
        }
    }
    final class State: @unchecked Sendable {
        let requests = AwaitableLog<URLRequest>()
        let connection = LockedValue<RecoveryServer?>(nil)
        func disconnect() { connection.current?.drop() }
        var handler: @Sendable (URLRequest) -> Reply
        init(_ handler: @escaping @Sendable (URLRequest) -> Reply) { self.handler = handler }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    static func serve(_ handler: @escaping @Sendable (URLRequest) -> Reply) -> (HermesBackend, State) {
        let host = "recovery-\(UUID().uuidString.lowercased()).test", state = State(handler)
        lock.withLock { states[host] = state }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        var backend = HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "fixture-key", session: URLSession(configuration: configuration))
        backend.statusScheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, firstBackoff: 0, jitter: { 0 }))
        backend.eventConnections = HermesEventConnections()
        backend.recoveryTiming = HermesRecoveryTiming(delays: [.zero, .zero, .zero], sleep: { _ in try Task.checkCancellation() })
        return (backend, state)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = Self.lock.withLock({ Self.states[request.url!.host!] }) else { return }
        var logged = request
        if logged.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                data.append(contentsOf: buffer.prefix(size))
            }
            logged.httpBody = data
        }
        state.requests.append(logged)
        let reply = state.handler(logged)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.hold ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        if reply.hold { _ = state.connection.swap(self) }
        client?.urlProtocol(self, didLoad: reply.data)
        if !reply.hold { client?.urlProtocolDidFinishLoading(self) }
    }
    func drop() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    override func stopLoading() {
        if let state = Self.lock.withLock({ Self.states[request.url!.host!] }), state.connection.current === self { _ = state.connection.swap(nil) }
    }
}

private var runFeatures: [String: Any] { [
    "session_chat_streaming": true, "run_submission": true, "run_events_sse": true, "run_status": true,
    "runs_idempotency": ["supported": true, "durable": true]
] }
private let recoveryTurn = AgentRequest(sessionID: "session", systemPrompt: "persona", messages: [(role: "user", content: "hello")])
private func route(_ request: URLRequest, features: [String: Any] = runFeatures, session: [String: Any] = [:]) -> RecoveryServer.Reply? {
    switch request.url!.path {
    case "/v1/capabilities": .json(["features": features])
    case "/api/sessions/session": .json(["session": session])
    case "/v1/runs": .json(["run_id": "run-1"], status: 202)
    default: nil
    }
}
private func collect(_ backend: HermesBackend) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in try await backend.send(recoveryTurn) { events.append(event) }
    return events
}
private func postCount(_ state: RecoveryServer.State) -> Int { state.requests.all.filter { $0.httpMethod == "POST" }.count }
private func tokens(_ events: [AgentEvent]) -> String { events.compactMap { if case .token(let text) = $0 { text } else { nil } }.joined() }
private func completed(_ events: [AgentEvent]) -> Bool { events.contains { if case .completed = $0 { true } else { false } } }

@Test func runReconnectReplaysMissedEventsWithoutResendingOrDuplicatingText() async throws {
    let subscriptions = LockedValue(0)
    let (backend, state) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        if request.url!.path.hasSuffix("/events") {
            let n = subscriptions.swap(subscriptions.current + 1)
            if n == 0 { return .events([["event": "message.delta", "seq": 0, "delta": "hello"]]) }
            if n == 1 { return .events([["event": "message.delta", "seq": 0, "delta": "hello"], ["event": "message.delta", "seq": 1, "delta": " world"]]) }
            return .events([["event": "run.completed", "seq": 2, "output": "hello world"]])
        }
        return .json(["status": "running"])
    }
    defer { backend.session.invalidateAndCancel() }
    let events = try await collect(backend)
    #expect(tokens(events) == "hello world" && completed(events))
    #expect(postCount(state) == 1)
    #expect(state.requests.all.filter { $0.url!.path.hasSuffix("/events") }.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["-1", "0", "1"])
    #expect(await backend.currentRunID(sessionID: "session") == nil)
    #expect(events.contains { if case .appNotice(let text) = $0 { text.contains("same reply") } else { false } })
}

@Test(arguments: ["completed", "failed", "cancelled", "interrupted"]) func runRecoveryPollsAuthoritativeTerminalOutput(status: String) async throws {
    let (backend, state) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        if request.url!.path.hasSuffix("/events") { return .events([["event": "message.delta", "seq": 0, "delta": "part"]]) }
        return .json(["status": status, "output": "full reply", "error": "specific failure", "pending_steer": "late guidance"])
    }
    defer { backend.session.invalidateAndCancel() }
    let events = try await collect(backend)
    #expect(completed(events) == (status == "completed"))
    #expect(events.contains { if case .replace("full reply") = $0 { true } else { false } })
    #expect(events.contains { if case .steer(.returned("late guidance")) = $0 { true } else { false } })
    #expect(postCount(state) == 1 && state.requests.all.filter { $0.url!.path.hasSuffix("/events") }.count == 1)
}

@Test func lostAdmissionAcknowledgementReplaysIdenticalRequestExactlyOnce() async throws {
    let submissions = AwaitableLog<URLRequest>()
    let (backend, state) = RecoveryServer.serve { request in
        if request.url!.path == "/v1/runs" {
            submissions.append(request)
            // The server reserved run-1, but its acceptance response was lost. Same key returns that run.
            if submissions.all.count == 1 { return .init(error: .networkConnectionLost) }
        }
        if let reply = route(request) { return reply }
        return .events([["event": "run.completed", "seq": 0, "output": "done"]])
    }
    defer { backend.session.invalidateAndCancel() }
    #expect(completed(try await collect(backend)))
    let sent = submissions.all
    #expect(sent.count == 2 && postCount(state) == 2)
    #expect(sent[0].value(forHTTPHeaderField: "Idempotency-Key") == sent[1].value(forHTTPHeaderField: "Idempotency-Key"))
    #expect(sent[0].value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
    #expect(sent[0].httpBody?.isEmpty == false)
    #expect(sent[0].httpBody == sent[1].httpBody && sent[0].url == sent[1].url)
}

@Test func twiceLostAdmissionStopsWithAmbiguousDeliveryAndNeverPostsAThirdTime() async throws {
    let (backend, state) = RecoveryServer.serve { request in
        if request.url!.path == "/v1/runs" { return .init(error: .networkConnectionLost) }
        return route(request) ?? .json([:])
    }
    defer { backend.session.invalidateAndCancel() }
    do { _ = try await collect(backend); Issue.record("Expected bounded submission recovery") }
    catch let error as StreamBreak { #expect(error.delivered) }
    #expect(postCount(state) == 2)
}

@Test func runReconnectBudgetEndsWithoutResubmittingEvenAfterOutput() async throws {
    let (backend, state) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        if request.url!.path.hasSuffix("/events") { return .events([["event": "message.delta", "seq": 0, "delta": "committed"]]) }
        return .json(["status": "running"])
    }
    defer { backend.session.invalidateAndCancel() }
    do { _ = try await collect(backend); Issue.record("Expected bounded reconnect") }
    catch let error as StreamBreak { #expect(error.delivered) }
    #expect(postCount(state) == 1)
    #expect(state.requests.all.filter { $0.url!.path.hasSuffix("/events") }.count == 4)
}

@Test func truncatedReplayStillFinishesWithTheFullOutput() async throws {
    let (backend, _) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        return .events([["event": "replay.truncated"], ["event": "message.delta", "seq": 50, "delta": "tail"], ["event": "run.completed", "seq": 51, "output": "full reply including missing prefix"]])
    }
    defer { backend.session.invalidateAndCancel() }
    let events = try await collect(backend)
    #expect(completed(events))
    #expect(events.contains { if case .replace("full reply including missing prefix") = $0 { true } else { false } })
}

@Test func wakeReconnectsOnlyTheDetachableSubscriptionToTheSameRun() async throws {
    let count = LockedValue(0)
    let (backend, state) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        if request.url!.path.hasSuffix("/events") {
            let n = count.swap(count.current + 1)
            return n == 0 ? .events([["event": "message.delta", "seq": 0, "delta": "before wake"]], hold: true) : .events([["event": "run.completed", "seq": 1, "output": "after wake"]])
        }
        return .json(["status": "running"])
    }
    defer { backend.session.invalidateAndCancel() }
    var iterator = try await backend.send(recoveryTurn).makeAsyncIterator()
    while let event = try await iterator.next() { if case .token("before wake") = event { break } }
    await backend.eventConnections.changed()
    var result: [AgentEvent] = []
    while let event = try await iterator.next() { result.append(event) }
    #expect(completed(result) && postCount(state) == 1 && count.current == 2)
}

@Test func cancellationDuringRecoveryDoesNotReconnectOrResend() async throws {
    let sleeping = AwaitableLog<Bool>()
    let (original, state) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        return .events([])
    }
    var backend = original
    backend.recoveryTiming.sleep = { _ in sleeping.append(true); try await Task.sleep(for: .seconds(300)) }
    let client = backend
    defer { client.session.invalidateAndCancel() }
    let consumer = Task { try await collect(client) }
    try await sleeping.wait { !$0.isEmpty }
    consumer.cancel()
    _ = await consumer.result
    #expect(postCount(state) == 1)
    #expect(state.requests.all.filter { $0.url!.path.hasSuffix("/events") }.count == 1)
}

@Test(arguments: ["lock", "opaqueConfig", "image", "management", "longText", "noIdempotency"]) func nativeContractsNeverSilentlySwitchToRuns(mode: String) async throws {
    let (backend, state) = RecoveryServer.serve { request in
        var features = runFeatures
        if mode == "noIdempotency" { features["runs_idempotency"] = ["supported": true, "durable": false] }
        let config: [String: Any] = mode == "opaqueConfig" ? ["has_model_config": true] : mode == "lock" ? ["model_config": ["browser_model_lock": ["confirmed": true]]] : [:]
        if let reply = route(request, features: features, session: config) { return reply }
        return .init(data: Data("event: assistant.completed\ndata: {\"content\":\"native\"}\n\n".utf8))
    }
    defer { backend.session.invalidateAndCancel() }
    var turn = recoveryTurn
    if mode == "image" { turn.images = ["data:image/png;base64,fixture"] }
    if mode == "management" { turn.managementText = "install with argument correlation" }
    if mode == "longText" { turn = .init(sessionID: "session", systemPrompt: "persona", messages: [(role: "user", content: String(repeating: "x", count: HermesBackend.maxTextPartScalars + 1))]) }
    for try await _ in try await backend.send(turn) {}
    #expect(!state.requests.all.contains { $0.url!.path == "/v1/runs" })
    #expect(state.requests.all.contains { $0.url!.path.hasSuffix("/chat/stream") })
}

@Test func submissionRetryNeverIncludesAuthenticationOrUserCancellation() {
    for error in [BackendError.http(401, "auth"), BackendError.http(403, "auth"), BackendError.http(409, "conflict")] {
        var recovery = HermesRunRecovery()
        let replay = recovery.replaySubmission(after: error)
        #expect(!replay)
    }
    var cancelled = HermesRunRecovery()
    let cancellationReplay = cancelled.replaySubmission(after: CancellationError())
    let urlCancellationReplay = cancelled.replaySubmission(after: URLError(.cancelled))
    #expect(!cancellationReplay && !urlCancellationReplay)
    var network = HermesRunRecovery()
    let firstReplay = network.replaySubmission(after: URLError(.networkConnectionLost))
    let secondReplay = network.replaySubmission(after: URLError(.networkConnectionLost))
    #expect(firstReplay && !secondReplay)
}

@Test func pathMonitorRecognizesSatisfiedInterfaceChangesAndRestoration() {
    let wifi = ConnectivityPath(satisfied: true, signature: "wifi")
    let ethernet = ConnectivityPath(satisfied: true, signature: "ethernet")
    let down = ConnectivityPath(satisfied: false, signature: "offline")
    #expect(wifi.event(after: nil) == nil)
    #expect(wifi.event(after: wifi) == nil)
    #expect(ethernet.event(after: wifi) == .pathChanged)
    #expect(down.event(after: wifi) == .pathDown)
    #expect(wifi.event(after: down) == .pathUp)
}

@Test func networkLossAfterACommittedTokenRecoversTheSameRun() async throws {
    let (backend, state) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        if request.url!.path.hasSuffix("/events") { return .events([["event": "message.delta", "seq": 0, "delta": "committed"]], hold: true) }
        return .json(["status": "completed", "output": "complete answer"])
    }
    defer { backend.session.invalidateAndCancel() }
    var iterator = try await backend.send(recoveryTurn).makeAsyncIterator()
    while let event = try await iterator.next() { if case .token("committed") = event { break } }
    state.disconnect()
    var events: [AgentEvent] = []
    while let event = try await iterator.next() { events.append(event) }
    #expect(completed(events) && postCount(state) == 1)
    #expect(events.contains { if case .replace("complete answer") = $0 { true } else { false } })
}

@Test func missingSubscriptionPollsTheRetainedResultWithoutResending() async throws {
    let (backend, state) = RecoveryServer.serve { request in
        if let reply = route(request) { return reply }
        if request.url!.path.hasSuffix("/events") { return .json(["error": "expired events"], status: 404) }
        return .json(["status": "completed", "output": "retained result"])
    }
    defer { backend.session.invalidateAndCancel() }
    #expect(completed(try await collect(backend)) && postCount(state) == 1)
}

@Test func errorsAfterAdmissionAreNeverReportedAsAnUnsentTurn() async throws {
    let (backend, state) = RecoveryServer.serve { request in
        route(request) ?? .json(["error": "key revoked"], status: 401)
    }
    defer { backend.session.invalidateAndCancel() }
    do { _ = try await collect(backend); Issue.record("Expected the failed event subscription") }
    catch let error as StreamBreak { #expect(error.delivered) }
    #expect(postCount(state) == 1)
}
