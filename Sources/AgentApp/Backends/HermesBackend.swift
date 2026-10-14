import Foundation

private actor HermesRunRegistry {
    static let shared = HermesRunRegistry()
    private var runs: [String: (token: UUID, runID: String)] = [:]
    func set(_ runID: String, for sessionID: String, token: UUID) { runs[sessionID] = (token, runID) }
    func get(_ sessionID: String) -> String? { runs[sessionID]?.runID }
    func clear(_ sessionID: String, token: UUID) {
        guard runs[sessionID]?.token == token else { return }
        runs.removeValue(forKey: sessionID)
    }
}

/// Forwards stream events and remembers whether a terminal one (`.completed` or `.failed`) went out.
final class EventSink: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let lock = NSLock(); private var terminal = false
    init(_ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) { self.continuation = continuation }
    var sawTerminal: Bool { lock.withLock { terminal } }
    func yield(_ event: AgentEvent) {
        switch event { case .completed, .failed: lock.withLock { terminal = true }; default: break }
        continuation.yield(event)
    }
}

/// Whether the response headers arrived, and whether `URLSessionTaskMetrics` show the request ever started.
final class StreamProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock(); private var open = false; private var started: Bool?
    var isOpen: Bool { lock.withLock { open } }
    var requestStarted: Bool? { lock.withLock { started } }
    func opened() { lock.withLock { open = true } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // Only a real transaction list counts; mock protocols report none, which says nothing.
        guard !metrics.transactionMetrics.isEmpty else { return }
        let value = metrics.transactionMetrics.contains { $0.requestStartDate != nil }
        lock.withLock { started = value }
    }
}

enum HermesTransport: Sendable, Equatable { case nativeSessions, legacyChatCompletions }

struct HermesAgentProfile: Sendable, Equatable { let id: String; let name: String; let model: String }

enum HermesProfileStatus: Sendable, Equatable {
    case available(HermesAgentProfile), prefixIgnored, unavailable(String)
    var reason: String? {
        switch self {
        case .available: nil
        case .prefixIgnored: HermesBackend.multiplexOffMessage
        case .unavailable(let value): value
        }
    }
}

/// `httpStatus` (P21, additive) is the status of a failed `/v1/models` answer, so callers map 401/403 without parsing text.
struct HermesProfileProbe: Sendable, Equatable { let id: String; let status: HermesProfileStatus; var httpStatus: Int? = nil }

struct HermesBackend: AgentBackend {
    let kind = BackendKind.hermes
    let baseURL: URL
    let apiKey: String
    var profile: String = "default"
    var session: URLSession = HermesURLSession.shared
    var timeouts = HermesTimeouts.standard

    static func validatedBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    static func permitsAPIKey(_ apiKey: String, at url: URL) -> Bool {
        guard !apiKey.isEmpty, url.scheme?.lowercased() == "http" else { return true }
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    func transport() async throws -> HermesTransport {
        try await features().contains("session_chat_streaming") ? .nativeSessions : .legacyChatCompletions
    }

    /// True `/v1/capabilities` feature flags, cached per server, profile and key; a 404 means none. Reads go through
    /// `capabilitiesJSON()` (P28 D6: one request for concurrent callers, a rejected key backs off).
    func features() async throws -> Set<String> {
        if let cached = await HermesCapabilityRegistry.shared.flags(for: capabilityScope) { return cached }
        let flags: Set<String>
        do {
            let features = try await capabilitiesJSON()["features"] as? [String: Any] ?? [:]
            flags = Set(features.compactMap { ($0.value as? Bool) == true ? $0.key : nil })
        } catch BackendError.http(let code, _) where code == 404 {
            flags = []
        }
        await HermesCapabilityRegistry.shared.setFlags(flags, for: capabilityScope)
        return flags
    }

    /// `POST /v1/runs/{run_id}/steer` with `{"input": text}`; Hermes answers 409 when the run no longer takes input.
    func steer(sessionID: String, text: String) async throws {
        guard try await features().contains("run_steer") else { throw BackendError.unavailable("This Hermes server cannot steer a running turn.") }
        guard let runID = await HermesRunRegistry.shared.get(sessionID) else { throw BackendError.unavailable("Hermes has not reported a run for this turn yet.") }
        let json = try await jsonRequest(path: "v1/runs/\(runID)/steer", method: "POST", body: ["input": text], timeout: timeouts.control)
        if (json["accepted"] as? Bool) == false { throw BackendError.unavailable("Hermes did not accept the steer message.") }
    }

    /// `POST /api/sessions/{id}/fork` with an optional `id`; Hermes copies the whole transcript into the new
    /// session, marks the source as branched (it stays usable) and returns `{"session": {"id": …}}`.
    func forkSession(sessionID: String, id: String?) async throws -> String {
        guard try await features().contains("session_fork") else { throw BackendError.unavailable("This Hermes server cannot fork a conversation.") }
        let escaped = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        let json = try await jsonRequest(path: "api/sessions/\(escaped)/fork", method: "POST", body: id.map { ["id": $0] } ?? [:])
        guard let session = json["session"] as? [String: Any], let forkID = session["id"] as? String else { throw BackendError.unavailable("Hermes returned no fork session ID.") }
        return forkID
    }

    func sessionTransport() async throws -> HermesTransport? { try await transport() }
    func currentRunID(sessionID: String) async -> String? { await HermesRunRegistry.shared.get(sessionID) }

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        if try await transport() == .nativeSessions { return try await sendSession(request) }
        return try await sendLegacyChat(request)
    }

    func listSessions() async throws -> [BackendSession] {
        guard try await transport() == .nativeSessions else { return [] }
        let json = try await jsonRequest(path: "api/sessions?source=api_server&limit=100&offset=0")
        let rows = (json["data"] as? [[String: Any]]) ?? (json["sessions"] as? [[String: Any]]) ?? []
        return GrokServerArchive.excludingArchives(rows).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return BackendSession(id: id, title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row["preview"] as? String) ?? "Hermes session")
        }
    }

    func loadMessages(sessionID: String) async throws -> [BackendMessage] {
        let escaped = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        guard try await transport() == .nativeSessions else { return [] }
        return try await Self.loadMessagePages { offset, limit in
            let json = try await jsonRequest(path: "api/sessions/\(escaped)/messages?order=oldest&limit=\(limit)&offset=\(offset)&inline_images=false")
            guard let rows = json["data"] as? [[String: Any]] else { throw BackendError.unavailable("Hermes returned an invalid messages page.") }
            return (rows.compactMap(Self.parseMessage), rows.count)
        }
    }

    static func loadMessagePages(pageSize: Int = 500, maximumPages: Int = 100, fetch: (Int, Int) async throws -> ([BackendMessage], Int)) async throws -> [BackendMessage] {
        var result: [BackendMessage] = []; var offset = 0
        for page in 0..<maximumPages {
            let (messages, rawCount) = try await fetch(offset, pageSize)
            result.append(contentsOf: messages)
            if rawCount < pageSize { return result }
            offset += rawCount
            if page == maximumPages - 1 { throw BackendError.unavailable("Hermes message history exceeded the \(pageSize * maximumPages)-row paging safety limit.") }
        }
        return result
    }

    func createSession(title: String, systemPrompt: String, id: String? = nil) async throws -> String {
        guard try await transport() == .nativeSessions else { throw BackendError.unavailable("Legacy Hermes servers do not support durable sessions.") }
        var body: [String: Any] = ["title": title, "system_prompt": systemPrompt, "source": "api_server"]
        if let id { body["id"] = id }
        let json: [String: Any]
        do { json = try await jsonRequest(path: "api/sessions", method: "POST", body: body, timeout: timeouts.read) }
        catch BackendError.http(let code, _) where code == 409 && id != nil { return id! }
        guard let session = json["session"] as? [String: Any], let id = session["id"] as? String else { throw BackendError.unavailable("Hermes returned no session ID.") }
        return id
    }

    func cancel(sessionID: String) async throws -> StopOutcome {
        try await requestStop(stopTarget(sessionID: sessionID))
    }

    func stopTarget(sessionID: String) async throws -> StopTarget {
        guard try await transport() == .nativeSessions else { return .disconnectedLegacy }
        guard let runID = await HermesRunRegistry.shared.get(sessionID) else { return .noActiveRun }
        return .serverRun(runID)
    }

    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        switch target {
        case .serverRun(let runID):
            _ = try await jsonRequest(path: "v1/runs/\(runID)/stop", method: "POST", body: [:], timeout: timeouts.control)
            return .requested
        case .disconnectedLegacy: return .disconnectedLegacy
        case .noActiveRun: return .noActiveRun
        }
    }

    /// A box row: integer `id` (a numeric string is accepted too), `finish_reason` kept; image data URLs in user rows
    /// (the box returns them whole) become a bare `[Image: inline]` line, which `comparable` ignores.
    static func parseMessage(_ row: [String: Any]) -> BackendMessage? {
        guard let role = row["role"] as? String, ["user", "assistant", "system"].contains(role),
              var content = normalizedContent(row["content"]), !content.isEmpty else { return nil }
        if role == "user", content.contains("[Image: data:") {
            content = content.components(separatedBy: "\n").map { $0.hasPrefix("[Image: data:") ? "[Image: inline]" : $0 }.joined(separator: "\n")
        }
        let rawDate = row["created_at"] ?? row["timestamp"]
        let date: Date?
        if let seconds = rawDate as? Double { date = Date(timeIntervalSince1970: seconds) }
        else if let seconds = rawDate as? Int { date = Date(timeIntervalSince1970: Double(seconds)) }
        else if let value = rawDate as? String { date = ISO8601DateFormatter().date(from: value) }
        else { date = nil }
        let rawID = row["id"] ?? row["message_id"]
        let id = (rawID as? Int) ?? (rawID as? String).flatMap { Int($0) }
        return .init(id: id, role: role, content: content, createdAt: date, finishReason: row["finish_reason"] as? String)
    }

    static func normalizedContent(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if value == nil || value is NSNull { return nil }
        if let object = value as? [String: Any] { return object["text"] as? String }
        guard let parts = value as? [Any] else { return nil }
        let rendered = parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            guard let object = part as? [String: Any] else { return nil }
            if let text = object["text"] as? String { return text }
            let image = object["image_url"]
            if let url = image as? String { return "[Image: \(url)]" }
            if let image = image as? [String: Any], let url = image["url"] as? String { return "[Image: \(url)]" }
            return nil
        }.filter { !$0.isEmpty }
        return rendered.isEmpty ? nil : rendered.joined(separator: "\n")
    }

    func resolveApproval(id: UUID, approved: Bool) async throws { throw BackendError.unavailable("The approval no longer identifies its Hermes run.") }

    func resolveApproval(_ approval: ApprovalRequest, approved: Bool) async throws {
        guard let runID = approval.runID else { throw BackendError.unavailable("The approval no longer identifies its Hermes run.") }
        var body: [String: Any] = ["choice": approved ? "once" : "deny"]
        if let requestID = approval.requestID { body["request_id"] = requestID }
        _ = try await jsonRequest(path: "v1/runs/\(runID)/approval", method: "POST", body: body)
    }

    func testConnection() async throws -> String {
        do {
            let json = try await jsonRequest(path: "health/detailed")
            return "Hermes \(json["version"] as? String ?? "unknown version") (\(json["status"] as? String ?? "ok"))"
        } catch BackendError.http(let code, _) where code == 404 {
            _ = try await jsonRequest(path: "health")
            return "Hermes healthy (legacy server; version unavailable)"
        }
    }

    static let multiplexOffMessage = "Server ignored the profile prefix — enable gateway.multiplex_profiles"

    func discoverProfiles(named names: [String] = [], keyFor: @escaping @Sendable (String) -> String = { KeychainStore.get(account: "hermes.\($0)") }) async throws -> [HermesAgentProfile] {
        let probes = await probeProfiles(named: names, keyFor: keyFor)
        if let first = probes.first, first.id == "default", case .unavailable(let reason) = first.status { throw BackendError.unavailable(reason) }
        return probes.compactMap { if case .available(let profile) = $0.status { profile } else { nil } }
    }

    /// Probes `default` plus each named profile via `/p/<profile>/v1/models`. With multiplexing off the
    /// gateway ignores the prefix and answers as the default agent, so a named profile only counts as
    /// available when the advertised model id equals the profile name. Reasons never contain keys.
    func probeProfiles(named names: [String], keyFor: @escaping @Sendable (String) -> String) async -> [HermesProfileProbe] {
        var result: [HermesProfileProbe] = []
        var seen: Set<String> = []
        for candidate in ["default"] + names where seen.insert(candidate).inserted {
            let key = candidate == "default" ? apiKey : keyFor(candidate)
            guard candidate == "default" || HermesKeyPaste.isValidProfileName(candidate) else { result.append(.init(id: candidate, status: .unavailable("Invalid profile name."))); continue }
            guard candidate == "default" || !key.isEmpty else { result.append(.init(id: candidate, status: .unavailable("No API key saved for this profile."))); continue }
            let backend = HermesBackend(baseURL: baseURL, apiKey: key, profile: candidate, session: session)
            do {
                let json = try await backend.jsonRequest(path: "v1/models")
                guard let first = (json["data"] as? [[String: Any]])?.first else { result.append(.init(id: candidate, status: .unavailable("Server listed no models."))); continue }
                let model = first["id"] as? String ?? "hermes-agent"
                if candidate != "default" && model != candidate { result.append(.init(id: candidate, status: .prefixIgnored)); continue }
                result.append(.init(id: candidate, status: .available(.init(id: candidate, name: candidate == "default" ? model : HermesProfileNaming.botName(forProfile: candidate), model: model))))
            } catch {
                let reason: String; var status: Int?
                if case BackendError.http(let code, _) = error { status = code; reason = code == 401 || code == 403 ? "HTTP \(code): the server rejected this key." : "HTTP \(code)." }
                else { reason = error.localizedDescription }
                result.append(.init(id: candidate, status: .unavailable(key.isEmpty ? reason : reason.replacingOccurrences(of: key, with: "[key]")), httpStatus: status))
            }
        }
        return result
    }

    private func sendSession(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let escaped = request.sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.sessionID
        var urlRequest = try makeRequest(path: "api/sessions/\(escaped)/chat/stream", method: "POST")
        let input = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        urlRequest.httpBody = try Self.requestBody(["input": Self.contentParts(text: input, images: request.images), "instructions": request.effectiveSystemPrompt])
        return sseStream(urlRequest, sessionID: request.sessionID, legacy: false)
    }

    private func sendLegacyChat(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        var urlRequest = try makeRequest(path: "v1/chat/completions", method: "POST")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
        // The persona stays one system string; every history message is split too, since Hermes cuts plain strings as well.
        let lastUser = request.messages.lastIndex { $0.role == "user" }
        var messages: [[String: Any]] = [["role": "system", "content": request.effectiveSystemPrompt]]
        messages.append(contentsOf: request.messages.enumerated().map { index, message in
            ["role": message.role, "content": Self.contentParts(text: message.content, images: index == lastUser ? request.images : [])]
        })
        urlRequest.httpBody = try Self.requestBody(["model": "hermes-agent", "stream": true, "messages": messages])
        return sseStream(urlRequest, sessionID: request.sessionID, legacy: true)
    }

    /// The chat stream. A turn ends only with a terminal event (`assistant.completed`, `run.completed`, the box's `error` /
    /// `run.failed`, legacy `[DONE]` or a failed finish chunk); EOF without one throws `StreamBreak(delivered: true)`, so
    /// does any error after the headers. An error before them is `StreamBreak(delivered: false)`; HTTP status errors stay
    /// `BackendError.http` and cancellation stays cancellation. Headers must arrive within the open deadline.
    private func sseStream(_ request: URLRequest, sessionID: String, legacy: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        var streamRequest = request; streamRequest.timeoutInterval = timeouts.streamIdle
        let request = streamRequest
        let deadline = timeouts.openDeadline(bodyBytes: request.httpBody?.count ?? 0)
        return AsyncThrowingStream { continuation in
            let streamToken = UUID(); let sink = EventSink(continuation); let probe = StreamProbe()
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            let bytes: URLSession.AsyncBytes, response: URLResponse
                            do { (bytes, response) = try await session.bytes(for: request, delegate: probe) }
                            catch let error as URLError where error.code != .cancelled { throw StreamBreak(delivered: false, underlying: error, requestStarted: probe.requestStarted) }
                            probe.opened()
                            try validate(response)
                            try await readEvents(bytes, sessionID: sessionID, legacy: legacy, token: streamToken, sink: sink)
                            return true
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(deadline))
                            if !probe.isOpen { throw StreamBreak(delivered: false, underlying: URLError(.timedOut)) }
                            return false
                        }
                        // The reader finishing first ends the deadline; the deadline passing after the headers waits for the reader.
                        if try await group.next() == false { _ = try await group.next() }
                        group.cancelAll()
                    }
                    await HermesRunRegistry.shared.clear(sessionID, token: streamToken); continuation.finish()
                } catch is CancellationError { await HermesRunRegistry.shared.clear(sessionID, token: streamToken); continuation.finish() }
                catch {
                    // URLSession commonly reports task cancellation as URLError.cancelled rather
                    // than CancellationError. Any terminal stream error must release the run ID.
                    await HermesRunRegistry.shared.clear(sessionID, token: streamToken)
                    if let urlError = error as? URLError, urlError.code == .cancelled, Task.isCancelled { continuation.finish() }
                    else if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func readEvents(_ bytes: URLSession.AsyncBytes, sessionID: String, legacy: Bool, token: UUID, sink: EventSink) async throws {
        var eventName = "message"
        var emittedAssistantDelta = false
        do {
            for try await line in bytes.lines {
                if line.hasPrefix("event:") { eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
                guard line.hasPrefix("data:") else { continue }
                let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if text == "[DONE]" { sink.yield(.completed); return }
                guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let runID = json["run_id"] as? String { await HermesRunRegistry.shared.set(runID, for: sessionID, token: token) }
                HermesStreamTap.shared.record(legacy ? "legacy:\(eventName)" : eventName, json)
                if !legacy, HermesRuntime.events.contains(eventName), let runtime = HermesRuntime.parse(json["runtime"]) {
                    await HermesRuntimeLog.shared.record(runtime, for: sessionID)
                }
                if legacy { parseLegacy(eventName, json, sink) } else { parseNative(eventName, json, sink, emittedAssistantDelta: &emittedAssistantDelta) }
                eventName = "message"
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled && Task.isCancelled { throw error }
        catch { throw StreamBreak(delivered: true, underlying: error) }
        if !sink.sawTerminal && !Task.isCancelled { throw StreamBreak(delivered: true, underlying: StreamBreak.EndOfStream()) }
    }

    private func parseLegacy(_ event: String, _ json: [String: Any], _ continuation: EventSink) {
        if event == "hermes.tool.progress" { continuation.yield(.tool(legacyTool(json))); return }
        if event == "hermes.failed" { continuation.yield(.failed(json["error"] as? String ?? json["message"] as? String ?? "Hermes run failed.")); return }
        let choice = (json["choices"] as? [[String: Any]])?.first
        if let delta = choice?["delta"] as? [String: Any], let content = delta["content"] as? String { continuation.yield(.token(content)) }
        if (choice?["finish_reason"] as? String) == "error" { continuation.yield(.failed("Hermes ended the reply with an error.")) }
    }

    private func parseNative(_ event: String, _ json: [String: Any], _ continuation: EventSink, emittedAssistantDelta: inout Bool) {
        switch event {
        case "assistant.delta", "message.delta": if let token = (json["delta"] ?? json["text"]) as? String { emittedAssistantDelta = true; continuation.yield(.token(token)) }
        case "tool.started", "tool.completed", "tool.failed", "tool.progress": continuation.yield(.tool(nativeTool(event, json)))
        case "assistant.commentary": if (json["already_streamed"] as? Bool) != true, let text = json["text"] as? String { continuation.yield(.token(text)) }
        case "subagent.start": continuation.yield(.subAgent(.init(id: UUID(), title: json["task"] as? String ?? json["label"] as? String ?? "Delegated task", detail: json["profile"] as? String ?? "", status: .running)))
        case "subagent.complete": continuation.yield(.subAgent(.init(id: UUID(), title: json["task"] as? String ?? "Delegated task", detail: json["summary"] as? String ?? "", status: (json["status"] as? String) == "completed" ? .completed : .failed)))
        case "assistant.completed":
            if !emittedAssistantDelta, let content = json["content"] as? String, !content.isEmpty { continuation.yield(.token(content)) }
            if let text = json["pending_steer"] as? String, !text.isEmpty { continuation.yield(.steer(.returned(text))) }
            continuation.yield(.completed)
        case "approval.request":
            // v0.21.7 emits `command` at the top level. Pollable run status and some
            // compatible gateways wrap the same approval object, so inspect those too.
            let wrapped = [json["approval"], json["data"]].compactMap { $0 as? [String: Any] }
            let sources = [json] + wrapped
            func firstNonempty(_ key: String) -> (String, [String: Any])? {
                for source in sources {
                    if let value = source[key] as? String {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return (trimmed, source) }
                    }
                }
                return nil
            }
            // Only the raw command may drive automation. A display string can be
            // shortened or redacted, so retain it solely as user-facing summary text.
            let rawCommandSource = firstNonempty("command")
            let displayCommandSource = firstNonempty("display_command")
            let command = rawCommandSource?.0
            let identity = rawCommandSource?.1 ?? displayCommandSource?.1 ?? json
            let runID = (identity["run_id"] as? String) ?? (json["run_id"] as? String)
            let requestID = (identity["request_id"] as? String) ?? (json["request_id"] as? String)
            let actionKind = firstNonempty("action_kind")?.0 ?? firstNonempty("tool_name")?.0 ?? firstNonempty("action")?.0 ?? "command"
            continuation.yield(.approval(.init(id: UUID(), title: json["description"] as? String ?? "Hermes needs approval", summary: command ?? displayCommandSource?.0 ?? "Command unknown", draft: nil, command: command, runID: runID, requestID: requestID, actionKind: actionKind)))
        case "run.completed":
            if let text = json["pending_steer"] as? String, !text.isEmpty { continuation.yield(.steer(.returned(text))) }
            continuation.yield(.completed)
        // P28: the box queued a steer for this run (it lands after the current tool batch).
        case "run.steered": continuation.yield(.steer(.accepted))
        // The box closed the run without a full answer (another client's Stop); the reconcile reads what it kept.
        case "run.cancelled": continuation.yield(.failed("The box cancelled this run."))
        case "run.failed", "error": continuation.yield(.failed(json["error"] as? String ?? json["message"] as? String ?? "Hermes run failed."))
        default: break
        }
    }

    func jsonRequest(path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: method, body: body, timeout: timeout); try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendError.unavailable("Hermes returned invalid JSON.") }
        return json
    }

    /// Authenticated, profile-prefixed request whose status the caller inspects (e.g. a 424 body that still names the saved job).
    func rawRequest(path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        var request = try makeRequest(path: path, method: method)
        if let timeout { request.timeoutInterval = timeout }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await session.data(for: request)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard Self.permitsAPIKey(apiKey, at: baseURL) else { throw BackendError.unavailable("Hermes API keys require HTTPS unless the server is loopback.") }
        guard let url = endpoint(path) else { throw BackendError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeouts.timeout(forMethod: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func endpoint(_ path: String) -> URL? {
        var root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")); if root.hasSuffix("/v1") { root.removeLast(3) }
        let prefix = profile == "default" ? "" : "/p/\(profile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile)"
        return URL(string: root + prefix + "/" + path)
    }

    func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError.unavailable("Hermes returned no HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]; let nested = json?["error"] as? [String: Any]
            let message = nested?["message"] as? String ?? json?["detail"] as? String ?? json?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "Hermes rejected the request."
            throw BackendError.http(http.statusCode, message)
        }
    }
}
