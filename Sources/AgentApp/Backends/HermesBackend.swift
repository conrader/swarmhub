import Foundation

struct HermesBackend: AgentBackend {
    let kind = BackendKind.hermes
    let baseURL: URL
    let apiKey: String

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let url = chatURL
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var messages = [["role": "system", "content": request.systemPrompt]]
        messages.append(contentsOf: request.messages.map { ["role": $0.role, "content": $0.content] })
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: ["model": "hermes-agent", "stream": true, "messages": messages])
        let finalRequest = urlRequest

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: finalRequest)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw BackendError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "Hermes rejected the request")
                    }
                    var eventName = "message"
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") { eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
                        guard line.hasPrefix("data:") else { continue }
                        let dataText = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if dataText == "[DONE]" { continuation.yield(.completed); break }
                        guard let data = dataText.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if eventName == "hermes.tool.progress" {
                            let label = json["message"] as? String ?? json["name"] as? String ?? "Using tool"
                            continuation.yield(.status(label)); eventName = "message"; continue
                        }
                        if let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any], let content = delta["content"] as? String { continuation.yield(.token(content)) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async { /* Chat Completions cancels by closing the stream. */ }
    func resolveApproval(id: UUID, approved: Bool) async throws { throw BackendError.unavailable("Use Hermes Runs API for approval resolution.") }
    func testConnection() async throws -> String {
        let health = rootURL.appending(path: "health")
        var request = URLRequest(url: health); if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw BackendError.unavailable("Hermes health check failed") }
        return "Hermes is healthy"
    }
    private var chatURL: URL {
        let clean = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: clean.hasSuffix("/v1") ? clean + "/chat/completions" : clean + "/v1/chat/completions")!
    }
    private var rootURL: URL {
        let text = baseURL.absoluteString.replacingOccurrences(of: "/v1/?$", with: "/", options: .regularExpression)
        return URL(string: text) ?? baseURL
    }
}
