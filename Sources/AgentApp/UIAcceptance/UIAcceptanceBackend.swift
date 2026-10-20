#if DEBUG
import Combine
import CryptoKit
import Foundation

/// Deliberately cannot forward a chat or invoke a tool. The three acceptance actions use the fake below.
struct UIAcceptanceChatBackend: AgentBackend {
    let kind = BackendKind.mock
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        throw UIAcceptanceError.invalidOperation
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func resolveApproval(id: UUID, approved: Bool) async throws { throw UIAcceptanceError.invalidOperation }
    func testConnection() async throws -> String { "In-process acceptance backend" }
}

@MainActor final class UIAcceptanceBackend: ObservableObject {
    struct SendAttempt: Codable, Equatable, Identifiable {
        let id: UUID
        let sourceID: UUID
        let conversationID: UUID
        let index: Int
        let to: String?
        let subject: String?
        let body: String
        let simulated: Bool
        let delivered: Bool
    }
    let directory: URL
    let keys = MemoryKeyStore()
    @Published private(set) var attempts: [SendAttempt] = []
    @Published private(set) var decisions: [String] = []
    @Published private(set) var secretSaved = false
    private(set) var records: [String: ManagedRecord] = [:]
    private var owners: [String: UUID] = [:]
    var secretPrompt: SecretRequestPrompt?

    init(directory: URL) { self.directory = directory }

    func seed(bot: Bot, remote: Bool) throws -> ApprovalRequest {
        let id = "task." + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let spec = ManagedRecord.Spec(kind: "outbound", bot: "acceptance", intent: remote ? "remote-dummy" : "managed-dummy",
                                      to: "a@example.invalid", text: "Acceptance fixture only", fake: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(spec)).map { String(format: "%02x", $0) }.joined()
        var record = ManagedRecord(id: id, fingerprint: fingerprint, gate: "owner", status: "awaiting-owner",
                                   decider: "acceptance", spec: spec)
        if remote {
            record.remoteBinding = .init(origin: "https://acceptance.invalid", runtime: UUID().uuidString, profile: "acceptance")
        }
        records[id] = record; owners[id] = bot.id
        return try record.request(botID: bot.id)
    }

    /// Uses the same operation/receipt contract as AppStore's real reconciliation, with no transport.
    func control(bot: Bot, verb: String, task: String, input: Data?) throws -> ManagedRecord {
        guard let record = records[task], owners[task] == bot.id, bot.hermesProfile == record.decider else {
            throw UIAcceptanceError.invalidOperation
        }
        guard bot.hermesBaseURL == record.remoteBinding?.origin else { throw UIAcceptanceError.invalidOperation }
        if verb == "get", input == nil { return record }
        struct Decision: Decodable {
            let approved: Bool; let fingerprint: String; let gate: String
            let binding: ManagedRecord.RemoteBinding?
        }
        guard verb == "decide", let input else { throw UIAcceptanceError.invalidOperation }
        let choice = try JSONDecoder().decode(Decision.self, from: input)
        guard choice.fingerprint == record.fingerprint, choice.gate == record.gate,
              choice.binding == record.remoteBinding else { throw UIAcceptanceError.invalidOperation }
        if !record.awaiting {
            guard record.confirms(choice.approved, original: record) else { throw UIAcceptanceError.invalidOperation }
            return record
        }
        var receipt = ManagedRecord(id: record.id, fingerprint: record.fingerprint, gate: record.gate,
                                    status: choice.approved ? "done" : "denied", decider: record.decider, spec: record.spec,
                                    decided_by: record.decider, decided_at: Date().timeIntervalSince1970)
        receipt.remoteBinding = record.remoteBinding
        if record.remoteBinding != nil { receipt.remoteReceipt = .init(id: UUID().uuidString, approved: choice.approved) }
        records[task] = receipt
        decisions.append("\(task): \(choice.approved ? "approved" : "denied") · simulated; no operation executed")
        return receipt
    }

    func saveSecret(_ prompt: SecretRequestPrompt, value: String) throws {
        guard prompt == secretPrompt, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UIAcceptanceError.invalidOperation
        }
        keys.setKey(value, for: "acceptance.dummy")
        secretSaved = true
    }

    func recordSend(sourceID: UUID, conversationID: UUID, index: Int, draft: DraftCard) throws -> SendAttempt {
        if let earlier = attempts.first(where: { $0.sourceID == sourceID && $0.index == index }) {
            guard earlier.conversationID == conversationID, earlier.to == draft.to,
                  earlier.subject == draft.subject, earlier.body == draft.body else { throw UIAcceptanceError.invalidOperation }
            return earlier
        }
        guard draft.to == "a@example.invalid", draft.subject == "Acceptance draft", draft.body == "Dummy message. Nothing is sent." else {
            throw UIAcceptanceError.invalidOperation
        }
        let attempt = SendAttempt(id: UUID(), sourceID: sourceID, conversationID: conversationID, index: index,
                                  to: draft.to, subject: draft.subject, body: draft.body, simulated: true, delivered: false)
        // Persist before showing success; an I/O failure never falls back to a provider.
        try QAMode.writePrivate(try JSONEncoder().encode(attempt), to: directory.appending(path: "send-\(attempt.id).json"))
        attempts.append(attempt)
        return attempt
    }
}
#endif
