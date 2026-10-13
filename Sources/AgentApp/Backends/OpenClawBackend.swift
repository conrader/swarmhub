import Foundation

/// Partial adapter scaffold. OpenClaw uses its authenticated WebSocket RPC protocol,
/// including `chat.send`, `chat.history`, `sessions.list`, and approval event families.
struct OpenClawBackend: AgentBackend {
    let kind = BackendKind.openClaw
    let gatewayURL: URL?
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> { throw BackendError.unavailable("OpenClaw WebSocket handshake is not implemented in this prototype.") }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .disconnectedLegacy }
    func resolveApproval(id: UUID, approved: Bool) async throws { throw BackendError.unavailable("OpenClaw approvals are not implemented yet.") }
    func testConnection() async throws -> String { throw BackendError.unavailable("OpenClaw adapter is a protocol-aligned stub.") }
}
