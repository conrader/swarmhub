import Foundation

struct AgentRequest: Sendable {
    let sessionID: String
    let systemPrompt: String
    let messages: [(role: String, content: String)]
}

protocol AgentBackend: Sendable {
    var kind: BackendKind { get }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func listSessions() async throws -> [BackendSession]
    func cancel(sessionID: String) async
    func resolveApproval(id: UUID, approved: Bool) async throws
    func testConnection() async throws -> String
}

enum BackendError: LocalizedError {
    case invalidURL, unavailable(String), http(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "The backend URL is invalid."
        case .unavailable(let value): value
        case .http(let code, let value): "HTTP \(code): \(value)"
        }
    }
}
