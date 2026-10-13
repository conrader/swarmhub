import Foundation

struct AgentRequest: Sendable {
    let sessionID: String
    let systemPrompt: String
    let messages: [(role: String, content: String)]
}

protocol AgentBackend: Sendable {
    var kind: BackendKind { get }
    func sessionTransport() async throws -> HermesTransport?
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func listSessions() async throws -> [BackendSession]
    func loadMessages(sessionID: String) async throws -> [BackendMessage]
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String
    func cancel(sessionID: String) async throws -> StopOutcome
    func stopTarget(sessionID: String) async throws -> StopTarget
    func requestStop(_ target: StopTarget) async throws -> StopOutcome
    func resolveApproval(id: UUID, approved: Bool) async throws
    func resolveApproval(_ approval: ApprovalRequest, approved: Bool) async throws
    func testConnection() async throws -> String
}

extension AgentBackend {
    func sessionTransport() async throws -> HermesTransport? { nil }
    func loadMessages(sessionID: String) async throws -> [BackendMessage] { [] }
    func createSession(title: String, systemPrompt: String, id: String? = nil) async throws -> String { id ?? UUID().uuidString }
    func resolveApproval(_ approval: ApprovalRequest, approved: Bool) async throws { try await resolveApproval(id: approval.id, approved: approved) }
    func stopTarget(sessionID: String) async throws -> StopTarget { .disconnectedLegacy }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        switch target {
        case .serverRun: return .noActiveRun
        case .disconnectedLegacy: return .disconnectedLegacy
        case .noActiveRun: return .noActiveRun
        }
    }
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
