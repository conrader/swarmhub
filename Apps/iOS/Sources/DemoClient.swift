import Foundation
import SwarmHubCore

/// Explicit local samples. The demo client has no network session or credential store.
actor DemoClient: AgentClient {
    private var history: [TranscriptMessage] = [
        .init(id: "demo-user", role: .user, text: "Find a simple direction for our mobile launch."),
        .init(id: "demo-reply", role: .assistant, text: "Start with the work your agents finish while you’re away. Keep conversations, routine results and approvals within reach.")
    ]
    init(history: [TranscriptMessage]? = nil) { if let history { self.history = history } }
    func verify() async throws -> ProfileVerification { .init(name: "Sample agent", capabilities: try await capabilities()) }
    func capabilities() async throws -> ServerCapabilities { .init(features: ["session_chat_streaming"]) }
    func sessions() async throws -> [SessionSummary] { [.init(id: "sample-session", title: "Mobile launch · sample")] }
    func createSession(title: String) async throws -> String { "sample-session" }
    func messages(sessionID: String) async throws -> [TranscriptMessage] { history }
    nonisolated func stream(sessionID: String, text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.reply(text, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func reply(_ text: String, continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) async {
        history.append(.init(id: UUID().uuidString, role: .user, text: text))
        continuation.yield(.started("sample-run"))
        let result = "This is a local sample reply. Connect your Hermes server in Settings to work with a real agent."
        do {
            for word in result.split(separator: " ") {
                try await Task.sleep(for: .milliseconds(35))
                continuation.yield(.delta(String(word) + " "))
            }
            history.append(.init(id: UUID().uuidString, role: .assistant, text: result))
            continuation.yield(.terminal(.completed)); continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
    func stop(runID: String) async throws { throw CoreError.unsupported("Stopping real runs requires a connected server.") }
    func steer(runID: String, text: String) async throws { throw CoreError.unsupported("Guidance requires a connected server.") }
    func resolve(_ approval: ApprovalItem, approved: Bool) async throws { throw CoreError.unsupported("Sample agents cannot grant approvals.") }
    func run(runID: String) async throws -> RunSnapshot { .init(state: .completed, status: "completed") }
}
