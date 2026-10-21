import Foundation
import SwarmHubCore

/// Count the JSON-encoded, fully composed instructions, including policy, persona and heartbeat.
/// This is deliberately below the provider's 1 MiB string limit, including JSON escaping overhead.
struct SkillInstallPayloadError: LocalizedError {
    static let instructionsByteBudget = 512 * 1024
    let bytes: Int
    var errorDescription: String? {
        "Client-side install payload error: encoded instructions are \(bytes) bytes (budget \(Self.instructionsByteBudget)); nothing was sent. Use the signed box transport for this bot."
    }

    static func validate(_ request: AgentRequest, policy: String?) throws {
        let instructions = BotSystemPrompt.compose(policy: policy, instructions: request.effectiveSystemPrompt)
        let bytes = try JSONSerialization.data(withJSONObject: ["instructions": instructions]).count
        guard bytes <= instructionsByteBudget else { throw Self(bytes: bytes) }
    }

    static func isPayloadError(_ end: TurnEnd) -> Bool {
        switch end {
        case .error(let error):
            if error is Self { return true }
            if let broken = error as? StreamBreak { return isPayloadError(.error(broken.underlying)) }
            if case BackendError.http(let code, let text) = error {
                return code == 413 || ([400, 422].contains(code) && matches(text))
            }
            // Providers also return these diagnostics inside a successful SSE HTTP response.
            return matches(error.localizedDescription)
        case .failedByBox(let text): return matches(text)
        default: return false
        }
    }

    private static func matches(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["string too long", "context_length", "context length", "context-length", "maximum context",
                "request too large", "request-too-large", "request_too_large", "payload too large",
                HermesBackend.requestTooLargeMessage.lowercased()].contains { text.contains($0) }
    }
}

struct SkillInstallResult: Equatable {
    enum Status: Equatable { case installed, failed, clientPayloadError, peerEnableBlocked, peerEnableUnverified, notSent }
    let status: Status
    let detail: String
}

extension AppStore {
    /// Results appear per bot in the manager's chat and persist with that transcript, even after its gap disappears.
    func recordSkillInstallResult(_ result: SkillInstallResult, bot: Bot, manager: Bot) {
        skillInstallResults[bot.id] = result
        manager.messages.append(ChatMessage(role: .system, content: "\(bot.name) (\(profile(of: bot))): \(result.detail)",
                                           metadata: [TurnKey.tone: "warning", "skill-install-result": bot.id.uuidString]))
        objectWillChange.send(); save()
    }
}
