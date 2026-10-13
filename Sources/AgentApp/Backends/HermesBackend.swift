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

private actor HermesCapabilityRegistry {
    static let shared = HermesCapabilityRegistry()
    private var values: [String: Bool] = [:]
    func value(for key: String) -> Bool? { values[key] }
    func set(_ value: Bool, for key: String) { values[key] = value }
}

enum HermesTransport: Sendable, Equatable { case nativeSessions, legacyChatCompletions }

struct HermesAgentProfile: Sendable, Equatable { let id: String; let name: String; let model: String }

struct HermesBackend: AgentBackend {
    let kind = BackendKind.hermes
    let baseURL: URL
    let apiKey: String
    var profile: String = "default"
    var session: URLSession = .shared

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
        let cacheKey = "\(baseURL.absoluteString)|\(profile)"
        if let cached = await HermesCapabilityRegistry.shared.value(for: cacheKey) {
            return cached ? .nativeSessions : .legacyChatCompletions
        }
        let native: Bool
        do {
            let json = try await jsonRequest(path: "v1/capabilities")
            let features = json["features"] as? [String: Any]
            native = (features?["session_chat_streaming"] as? Bool) == true
        } catch BackendError.http(let code, _) where code == 404 {
            native = false
        }
        await HermesCapabilityRegistry.shared.set(native, for: cacheKey)
        return native ? .nativeSessions : .legacyChatCompletions
    }
    func sessionTransport() async throws -> HermesTransport? { try await transport() }

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        if try await transport() == .nativeSessions { return try await sendSession(request) }
        return try await sendLegacyChat(request)
    }

    func listSessions() async throws -> [BackendSession] {
        guard try await transport() == .nativeSessions else { return [] }
        let json = try await jsonRequest(path: "api/sessions?source=api_server&limit=100&offset=0")
        let rows = (json["data"] as? [[String: Any]]) ?? (json["sessions"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
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
        do { json = try await jsonRequest(path: "api/sessions", method: "POST", body: body) }
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
            _ = try await jsonRequest(path: "v1/runs/\(runID)/stop", method: "POST", body: [:], timeout: 8)
            return .requested
        case .disconnectedLegacy: return .disconnectedLegacy
        case .noActiveRun: return .noActiveRun
        }
    }

    private static func parseMessage(_ row: [String: Any]) -> BackendMessage? {
        guard let role = row["role"] as? String, ["user", "assistant", "system"].contains(role),
              let content = normalizedContent(row["content"]), !content.isEmpty else { return nil }
        let rawDate = row["created_at"] ?? row["timestamp"]
        let date: Date?
        if let seconds = rawDate as? Double { date = Date(timeIntervalSince1970: seconds) }
        else if let seconds = rawDate as? Int { date = Date(timeIntervalSince1970: Double(seconds)) }
        else if let value = rawDate as? String { date = ISO8601DateFormatter().date(from: value) }
        else { date = nil }
        return .init(id: (row["id"] ?? row["message_id"]) as? String, role: role, content: content, createdAt: date)
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

    func discoverProfiles(named names: [String] = []) async throws -> [HermesAgentProfile] {
        var result: [HermesAgentProfile] = []
        for candidate in ["default"] + names.filter({ $0 != "default" }) {
            let key = candidate == "default" ? apiKey : KeychainStore.get(account: "hermes.\(candidate)")
            let backend = HermesBackend(baseURL: baseURL, apiKey: key, profile: candidate, session: session)
            do {
                let json = try await backend.jsonRequest(path: "v1/models")
                guard let first = (json["data"] as? [[String: Any]])?.first else { continue }
                let model = first["id"] as? String ?? "hermes-agent"
                result.append(.init(id: candidate, name: candidate == "default" ? model : candidate, model: model))
            } catch let error where candidate == "default" { throw error }
            catch { continue }
        }
        return result
    }

    private func sendSession(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let escaped = request.sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.sessionID
        var urlRequest = try makeRequest(path: "api/sessions/\(escaped)/chat/stream", method: "POST")
        let input = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: ["input": input, "instructions": request.systemPrompt])
        return sseStream(urlRequest, sessionID: request.sessionID, legacy: false)
    }

    private func sendLegacyChat(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        var urlRequest = try makeRequest(path: "v1/chat/completions", method: "POST")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
        var messages = [["role": "system", "content": request.systemPrompt]]
        messages.append(contentsOf: request.messages.map { ["role": $0.role, "content": $0.content] })
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: ["model": "hermes-agent", "stream": true, "messages": messages])
        return sseStream(urlRequest, sessionID: request.sessionID, legacy: true)
    }

    private func sseStream(_ request: URLRequest, sessionID: String, legacy: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamToken = UUID()
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request); try validate(response)
                    var eventName = "message"
                    var emittedAssistantDelta = false
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") { eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
                        guard line.hasPrefix("data:") else { continue }
                        let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if text == "[DONE]" { continuation.yield(.completed); break }
                        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let runID = json["run_id"] as? String { await HermesRunRegistry.shared.set(runID, for: sessionID, token: streamToken) }
                        if legacy { parseLegacy(eventName, json, continuation) } else { parseNative(eventName, json, continuation, emittedAssistantDelta: &emittedAssistantDelta) }
                        eventName = "message"
                    }
                    await HermesRunRegistry.shared.clear(sessionID, token: streamToken); continuation.finish()
                } catch is CancellationError { await HermesRunRegistry.shared.clear(sessionID, token: streamToken); continuation.finish() }
                catch {
                    // URLSession commonly reports task cancellation as URLError.cancelled rather
                    // than CancellationError. Any terminal stream error must release the run ID.
                    await HermesRunRegistry.shared.clear(sessionID, token: streamToken)
                    if let urlError = error as? URLError, urlError.code == .cancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func parseLegacy(_ event: String, _ json: [String: Any], _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) {
        if event == "hermes.tool.progress" { continuation.yield(.status(json["message"] as? String ?? json["name"] as? String ?? "Using tool")); return }
        if let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any], let content = delta["content"] as? String { continuation.yield(.token(content)) }
    }

    private func parseNative(_ event: String, _ json: [String: Any], _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation, emittedAssistantDelta: inout Bool) {
        switch event {
        case "assistant.delta", "message.delta": if let token = (json["delta"] ?? json["text"]) as? String { emittedAssistantDelta = true; continuation.yield(.token(token)) }
        case "tool.started", "tool.completed", "tool.failed", "tool.progress": continuation.yield(.status((json["tool_name"] ?? json["tool"]) as? String ?? event))
        case "assistant.commentary": if (json["already_streamed"] as? Bool) != true, let text = json["text"] as? String { continuation.yield(.token(text)) }
        case "subagent.start": continuation.yield(.subAgent(.init(id: UUID(), title: json["task"] as? String ?? json["label"] as? String ?? "Delegated task", detail: json["profile"] as? String ?? "", status: .running)))
        case "subagent.complete": continuation.yield(.subAgent(.init(id: UUID(), title: json["task"] as? String ?? "Delegated task", detail: json["summary"] as? String ?? "", status: (json["status"] as? String) == "completed" ? .completed : .failed)))
        case "assistant.completed": if !emittedAssistantDelta, let content = json["content"] as? String, !content.isEmpty { continuation.yield(.token(content)) }
        case "approval.request":
            let command = (json["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.yield(.approval(.init(id: UUID(), title: json["description"] as? String ?? "Hermes needs approval", summary: command?.isEmpty == false ? command! : "Command unknown", draft: nil, command: command?.isEmpty == false ? command : nil, runID: json["run_id"] as? String, requestID: json["request_id"] as? String)))
        case "run.completed": continuation.yield(.completed)
        case "run.cancelled": continuation.yield(.completed)
        case "run.failed", "error": continuation.yield(.failed(json["error"] as? String ?? json["message"] as? String ?? "Hermes run failed."))
        default: break
        }
    }

    private func jsonRequest(path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        var request = try makeRequest(path: path, method: method)
        if let timeout { request.timeoutInterval = timeout }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request); try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendError.unavailable("Hermes returned invalid JSON.") }
        return json
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard Self.permitsAPIKey(apiKey, at: baseURL) else { throw BackendError.unavailable("Hermes API keys require HTTPS unless the server is loopback.") }
        guard let url = endpoint(path) else { throw BackendError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func endpoint(_ path: String) -> URL? {
        var root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")); if root.hasSuffix("/v1") { root.removeLast(3) }
        let prefix = profile == "default" ? "" : "/p/\(profile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile)"
        return URL(string: root + prefix + "/" + path)
    }

    private func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError.unavailable("Hermes returned no HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]; let nested = json?["error"] as? [String: Any]
            let message = nested?["message"] as? String ?? json?["detail"] as? String ?? json?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "Hermes rejected the request."
            throw BackendError.http(http.statusCode, message)
        }
    }
}
