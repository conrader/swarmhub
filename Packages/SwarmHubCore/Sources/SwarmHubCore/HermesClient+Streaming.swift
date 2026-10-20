import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension HermesClient {
    public func stream(sessionID: String, text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Self.validateID(sessionID)
                    guard try await capabilities().sessions else { throw CoreError.unsupported("Native chat needs this server’s Sessions API. Legacy chat is a later mobile milestone.") }
                    var request = try request(path: "api/sessions/\(sessionID)/chat/stream", method: "POST", body: ["input": HermesContent.parts(text: text), "instructions": try BotSystemPrompt.render(promptContext)])
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var decoder = SSEByteDecoder()
                    var terminal = false
                    #if canImport(Darwin)
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let frame = try decoder.consume(byte), let event = try Self.event(frame) {
                            continuation.yield(event)
                            if case .terminal = event { terminal = true; break }
                        }
                    }
                    #else
                    let (data, response) = try await session.data(for: request)
                    try Self.validate(response)
                    for byte in data {
                        if let frame = try decoder.consume(byte), let event = try Self.event(frame) {
                            continuation.yield(event)
                            if case .terminal = event { terminal = true; break }
                        }
                    }
                    #endif
                    guard terminal else { throw CoreError.interruptedStream }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func event(_ frame: SSEFrame) throws -> ChatEvent? {
        guard frame.data != "[DONE]" else { return nil } // EOF/done alone is not a confirmed run completion.
        guard let data = frame.data.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CoreError.invalidResponse }
        let name = frame.event == "message" ? json["event"] as? String ?? frame.event : frame.event
        switch name {
        case "run.started":
            guard let id = json["run_id"] as? String, ConnectionAddress.validResourceID(id) else { throw CoreError.invalidResponse }
            return .started(id)
        case "assistant.delta", "message.delta": return (json["delta"] as? String ?? json["text"] as? String).map(ChatEvent.delta)
        case "assistant.completed": return (json["content"] as? String).map(ChatEvent.snapshot)
        case "assistant.commentary": return json["already_streamed"] as? Bool == true ? nil : (json["text"] as? String).map(ChatEvent.delta)
        case "tool.started", "tool.completed", "tool.progress", "tool.failed": return .status(json["tool_name"] as? String ?? json["tool"] as? String ?? "Agent tool activity")
        case "approval.request":
            let payload = json["approval"] as? [String: Any] ?? json["data"] as? [String: Any] ?? json
            guard let runID = json["run_id"] as? String ?? payload["run_id"] as? String else { return .status("An approval request has no run identifier. Review it on desktop.") }
            return approval(payload, runID: runID).map(ChatEvent.approval)
        case "run.completed": return .terminal(.completed)
        case "run.cancelled": return .terminal(.cancelled)
        case "run.failed", "error": return .terminal(.failed)
        default: return nil
        }
    }

    static func approval(_ json: [String: Any], runID: String) -> ApprovalItem? {
        guard let requestID = json["request_id"] as? String, ConnectionAddress.validResourceID(runID), ConnectionAddress.validResourceID(requestID) else { return nil }
        return ApprovalItem(runID: runID, requestID: requestID, title: json["description"] as? String ?? "Review requested action", command: json["command"] as? String, choices: json["choices"] as? [String] ?? [])
    }
}
