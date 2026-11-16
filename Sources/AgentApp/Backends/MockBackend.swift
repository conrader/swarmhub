import Foundation

/// Answers locally, with no server: the sample agents ("Look around with sample agents") and tests.
struct MockBackend: AgentBackend {
    let kind = BackendKind.mock
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.status("Planning"))
                let reply = "This is a sample agent, so nothing ran. Set up a server to get a bot that works.\n\n```swift\nlet app = \"fast, native, private\"\n```"
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: .milliseconds(32))
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.token(String(word) + " "))
                }
                continuation.yield(.completed); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func cancel(sessionID: String) async throws -> StopOutcome { .noRunControl }
    func testConnection() async throws -> String { "Mock backend ready" }
}
