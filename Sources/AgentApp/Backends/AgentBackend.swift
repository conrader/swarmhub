import Foundation

struct AgentRequest: Sendable {
    let sessionID: String
    let systemPrompt: String
    let messages: [(role: String, content: String)]
    /// `data:image/...` URLs sent as image parts with the last user message.
    var images: [String] = []
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
    /// Feature flags the server reports as true at `/v1/capabilities` (empty when it has none).
    func features() async throws -> Set<String>
    /// Adds guidance to the session's running turn (`run_steer`).
    func steer(sessionID: String, text: String) async throws
    /// Branches the session (`session_fork`) and returns the new session id.
    func forkSession(sessionID: String, id: String?) async throws -> String
    /// P16: one window of the session's newest rows (`order=latest`, `offset` counted back from the newest), oldest first.
    func recentMessages(sessionID: String, window: Int, offset: Int) async throws -> MessagePage
    /// P16: the box's status of a run (`GET /v1/runs/{id}`, capability `run_status`); nil when unknown.
    func runStatus(runID: String) async throws -> String?
    /// P16: the run the session's current stream reported, for the row's `run` mark.
    func currentRunID(sessionID: String) async -> String?
}

/// P16: a window of box rows. `full`: the box returned as many rows as asked (there may be older ones);
/// `missing`: the box has no such session (404 `session_not_found`, not an error); `serverDate`: the GET's `Date` header.
struct MessagePage: Sendable, Equatable {
    var rows: [BackendMessage]; var full: Bool; var missing = false; var serverDate: Date? = nil; var bytes = 0
}

extension AgentBackend {
    func sessionTransport() async throws -> HermesTransport? { nil }
    func features() async throws -> Set<String> { [] }
    func steer(sessionID: String, text: String) async throws { throw BackendError.unavailable("This backend cannot steer a running turn.") }
    func forkSession(sessionID: String, id: String?) async throws -> String { throw BackendError.unavailable("This backend cannot fork a conversation.") }
    func loadMessages(sessionID: String) async throws -> [BackendMessage] { [] }
    /// The tail slice of `loadMessages`, so backends without paging still reconcile.
    func recentMessages(sessionID: String, window: Int, offset: Int) async throws -> MessagePage {
        let all = try await loadMessages(sessionID: sessionID)
        let end = max(0, all.count - offset), start = max(0, end - window)
        return MessagePage(rows: Array(all[start..<end]), full: start > 0)
    }
    func runStatus(runID: String) async throws -> String? { nil }
    func currentRunID(sessionID: String) async -> String? { nil }
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
