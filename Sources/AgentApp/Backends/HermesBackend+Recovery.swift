import Foundation
import SwarmHubCore

struct HermesRecoveryTiming: Sendable {
    var delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// A submission can be replayed only once, with identical bytes and the SAME durable server key.
/// Event retries never submit a turn. The sequence advances only after a complete JSON event was parsed.
struct HermesRunRecovery: Sendable {
    let idempotencyKey = UUID().uuidString
    private(set) var replayedSubmission = false
    private(set) var sequence = -1
    mutating func replaySubmission(after error: Error) -> Bool {
        guard !replayedSubmission, Self.transient(error) else { return false }
        replayedSubmission = true
        return true
    }
    mutating func accept(_ sequence: Int) -> Bool {
        guard sequence > self.sequence else { return false }
        self.sequence = sequence
        return true
    }
    static func transient(_ error: Error) -> Bool {
        if let error = error as? StreamBreak { return transient(error.underlying) || error.isEndOfStream }
        if let error = error as? URLError {
            return [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed].contains(error.code)
        }
        if case BackendError.http(let code, _) = error { return [429, 502, 503, 504].contains(code) }
        return error is HermesStatusDeferred
    }
}

/// Only detachable event subscriptions are cancelled on wake/path changes. A native POST must never be cancelled here.
actor HermesEventConnections {
    static let shared = HermesEventConnections()
    private var connections: [UUID: URLSessionTask] = [:]
    private var generation = 0
    func revision() -> Int { generation }
    func add(_ task: URLSessionTask, token: UUID, revision: Int) {
        if revision != generation { task.cancel() } else { connections[token] = task }
    }
    func remove(_ token: UUID) { connections[token] = nil }
    func changed() { generation += 1; connections.values.forEach { $0.cancel() }; connections = [:] }
}

extension HermesBackend {
    func sendDurableRun(_ turn: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        // /v1/runs does not implement the native endpoint's confirmed Browser lock semantics.
        // Preserve that contract, multipart normalization, and install tool-argument events on the native transport.
        let json = try await jsonRequest(path: "api/sessions/\(Self.escapedPath(turn.sessionID))")
        let row = json["session"] as? [String: Any] ?? [:]
        let config: [String: Any]
        if let value = row["model_config"] as? [String: Any] { config = value }
        else if let text = row["model_config"] as? String, let data = text.data(using: .utf8) {
            config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        } else { config = [:] }
        if (config["browser_model_lock"] as? [String: Any])?["confirmed"] as? Bool == true {
            return try sendNativeSession(turn)
        }
        var request = try makeRequest(path: "v1/runs", method: "POST")
        let recovery = HermesRunRecovery()
        request.setValue(recovery.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        var body: [String: Any] = [
            "session_id": turn.sessionID,
            "input": turn.messages.last(where: { $0.role == "user" })?.content ?? "",
            "instructions": BotSystemPrompt.compose(policy: defaultInstructions, instructions: turn.effectiveSystemPrompt)
        ]
        if let model = row["model"] as? String, !model.isEmpty { body["model"] = model }
        request.httpBody = try Self.requestBody(body)
        let submission = request
        // Mutated only by the stream's producer task.
        let initialRecovery = recovery
        return AsyncThrowingStream { continuation in
            let task = Task {
                var recovery = initialRecovery
                let token = UUID()
                do {
                    let runID: String
                    do { runID = try await admitRun(submission) }
                    catch {
                        try Task.checkCancellation()
                        guard recovery.replaySubmission(after: error) else { throw error }
                        continuation.yield(.status("Connection lost. Checking the same request again…"))
                        continuation.yield(.appNotice("Connection lost before confirmation. Retrying the same request once…"))
                        try await recoveryTiming.sleep(recoveryTiming.delays.first ?? .zero)
                        try Task.checkCancellation()
                        do { runID = try await admitRun(submission) }
                        catch { throw StreamBreak(delivered: true, underlying: error) }
                    }
                    await HermesRunRegistry.shared.set(runID, for: turn.sessionID, scope: capabilityScope, token: token)
                    // Ensure the UI records the run ID even before the first text/tool event.
                    continuation.yield(.status("Waiting for reply…"))
                    try await followRun(runID, sessionID: turn.sessionID, token: token, recovery: &recovery, continuation: continuation)
                    await HermesRunRegistry.shared.clear(turn.sessionID, scope: capabilityScope, token: token)
                    continuation.finish()
                } catch {
                    await HermesRunRegistry.shared.clear(turn.sessionID, scope: capabilityScope, token: token)
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func admitRun(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let id = json?["run_id"] as? String, !id.isEmpty else {
            throw StreamBreak(delivered: true, underlying: BackendError.unavailable("Hermes accepted no identifiable run. Check the conversation before retrying."))
        }
        return id
    }

    private func followRun(_ runID: String, sessionID: String, token: UUID, recovery: inout HermesRunRecovery,
                           continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        let sink = EventSink(continuation)
        var children = ChildTaskCorrelation(scope: sessionID)
        var emittedDelta = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let revision = await eventConnections.revision()
            do {
                var request = try makeRequest(path: "v1/runs/\(Self.escapedPath(runID))/events", method: "GET")
                request.timeoutInterval = timeouts.streamIdle
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue(String(recovery.sequence), forHTTPHeaderField: "Last-Event-ID")
                let (bytes, response) = try await session.bytes(for: request)
                await eventConnections.add(bytes.task, token: token, revision: revision)
                do {
                    try await validateStreamResponse(response, bytes: bytes)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        guard let data = line.dropFirst(5).data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let event = json["event"] as? String else {
                            throw StreamBreak(delivered: true, underlying: StreamBreak.EndOfStream())
                        }
                        // The final output replaces the preview even if the retained replay lost old deltas.
                        if event == "replay.truncated" { continue }
                        guard let seq = json["seq"] as? Int, recovery.accept(seq) else { continue }
                        HermesStreamTap.shared.record(event, json)
                        if let runtime = HermesRuntime.parse(json["runtime"]) { await HermesRuntimeLog.shared.record(runtime, for: sessionID) }
                        if event == "run.completed", let output = json["output"] as? String { sink.yield(.replace(output)) }
                        if event == "run.interrupted" { sink.yield(.failed("Hermes restarted during this reply. Check the conversation before retrying.")) }
                        else { parseNative(event == "message.interim" ? "assistant.commentary" : event, json, sink,
                                           emittedAssistantDelta: &emittedDelta, children: &children) }
                        if sink.sawTerminal { break }
                    }
                } catch {
                    bytes.task.cancel()
                    await eventConnections.remove(token)
                    throw error
                }
                bytes.task.cancel()
                await eventConnections.remove(token)
                if sink.sawTerminal { return }
                throw StreamBreak(delivered: true, underlying: StreamBreak.EndOfStream())
            } catch {
                try Task.checkCancellation()
                let pathChanged = await eventConnections.revision() != revision
                guard HermesRunRecovery.transient(error) || pathChanged else { throw error }
                guard attempt < recoveryTiming.delays.count else { throw StreamBreak(delivered: true, underlying: error) }
                continuation.yield(.status("Connection interrupted. Reconnecting to the reply…"))
                if attempt == 0 { continuation.yield(.appNotice("Connection interrupted. Reconnecting to the same reply…")) }
                try await recoveryTiming.sleep(recoveryTiming.delays[attempt])
                attempt += 1
                // Poll after the delay: the run may have finished while the Mac was offline. Output is authoritative.
                do {
                    let result = try await jsonRequest(path: "v1/runs/\(Self.escapedPath(runID))")
                    if let status = result["status"] as? String, ["completed", "failed", "cancelled", "interrupted"].contains(status) {
                        if let runtime = HermesRuntime.parse(result["runtime"]) { await HermesRuntimeLog.shared.record(runtime, for: sessionID) }
                        if let output = result["output"] as? String { sink.yield(.replace(output)) }
                        if let text = result["pending_steer"] as? String, !text.isEmpty { sink.yield(.steer(.returned(text))) }
                        if status == "completed", !Self.resultFailed(result) { sink.yield(.completed) }
                        else { sink.yield(.failed(failureMessage(result, fallback: "Hermes \(status) this run."))) }
                        return
                    }
                } catch {
                    try Task.checkCancellation()
                    guard HermesRunRecovery.transient(error) else { throw error }
                }
            }
        }
    }
}
