import Foundation

public protocol AgentClient: Sendable {
    func verify() async throws -> ProfileVerification
    func capabilities() async throws -> ServerCapabilities
    func sessions() async throws -> [SessionSummary]
    func createSession(title: String) async throws -> String
    func messages(sessionID: String) async throws -> [TranscriptMessage]
    func stream(sessionID: String, text: String) -> AsyncThrowingStream<ChatEvent, Error>
    func stop(runID: String) async throws
    func steer(runID: String, text: String) async throws
    func resolve(_ approval: ApprovalItem, approved: Bool) async throws
    func run(runID: String) async throws -> RunSnapshot
}
