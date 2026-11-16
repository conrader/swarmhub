import Foundation

struct AgentRequest: Sendable {
    let sessionID: String
    let systemPrompt: String
    let messages: [(role: String, content: String)]
    /// `data:image/...` URLs sent as image parts with the last user message.
    var images: [String] = []
}

/// What answers a bot's messages. `HerdrBackend` is the one real implementation (an agent that Herdr Core runs);
/// `MockBackend` answers locally for the sample agents.
protocol AgentBackend: Sendable {
    var kind: BackendKind { get }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(sessionID: String) async throws -> StopOutcome
    func stopTarget(sessionID: String) async throws -> StopTarget
    func requestStop(_ target: StopTarget) async throws -> StopOutcome
    func testConnection() async throws -> String
    /// What the running agent can do; `run_steer` means a message sent mid-turn reaches it.
    func features() async throws -> Set<String>
    /// Adds guidance to the running turn.
    func steer(sessionID: String, text: String) async throws
}

extension AgentBackend {
    func features() async throws -> Set<String> { [] }
    func steer(sessionID: String, text: String) async throws { throw BackendError.unavailable("This backend cannot steer a running turn.") }
    func stopTarget(sessionID: String) async throws -> StopTarget { .noRunControl }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        switch target {
        case .serverRun: return .noActiveRun
        case .noRunControl: return .noRunControl
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
