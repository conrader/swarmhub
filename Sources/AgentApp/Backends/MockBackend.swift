import Foundation

/// Answers locally, with no server: the sample agents ("Look around with sample agents") and tests.
struct MockBackend: AgentBackend {
    let kind = BackendKind.mock
    var sampleName: String?

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.status("Planning"))
                let reply: String
                if sampleName != nil, !request.images.isEmpty {
                    if let example = SampleScreenshot.dataURL, request.images.contains(example) {
                        reply = "In the sample screenshot, the “Keep editing” label (#888888) on its #555555 background has a contrast ratio of 2.10:1. White text on that background would reach 7.46:1."
                    } else {
                        reply = "The image is attached to this sample conversation. A connected bot with vision can inspect its contents."
                    }
                } else if let sampleName, let message = request.messages.last(where: { $0.role == "user" }) {
                    let text = String(message.content.prefix(220)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    reply = "\(sampleName) received your message in the sample chat: “\(text)”."
                } else {
                    reply = "This is a sample bot, so nothing ran. Set up a server to get a bot that works.\n\n```swift\nlet app = \"fast, native, private\"\n```"
                }
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
