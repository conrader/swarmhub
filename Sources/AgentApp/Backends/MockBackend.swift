import Foundation

struct MockBackend: AgentBackend {
    let kind = BackendKind.mock
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let taskID = UUID()
                continuation.yield(.status("Planning"))
                continuation.yield(.subAgent(.init(id: taskID, title: "Research details", detail: "Scanning local context", status: .running)))
                let reply = "I’ve started a sub-agent and prepared a concise answer.\n\n```swift\nlet app = \"fast, native, private\"\n```\n\nHere’s a draft action for your review before anything is sent."
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: .milliseconds(32))
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.token(String(word) + " "))
                }
                continuation.yield(.subAgent(.init(id: taskID, title: "Research details", detail: "Found and summarized context", status: .completed)))
                continuation.yield(.approval(.init(id: UUID(), title: "Send email?", summary: "An outgoing email needs your approval.", draft: "To: team@example.com\nSubject: Project update\n\nThe native prototype is ready for review.")))
                continuation.yield(.completed); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async {}
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "Mock backend ready" }
}
