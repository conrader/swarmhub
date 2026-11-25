import Foundation

struct DismissedError: Codable, Identifiable {
    enum Reason: String, Codable {
        case terminal, stop, setup, agent, send, capacity, card, attachment, storage, connection, operation

        var explanation: String {
            switch self {
            case .terminal: "The agent’s terminal could not be opened."
            case .stop: "SwarmHub could not confirm that the agent stopped."
            case .setup: "The requested agent or model was unavailable on this server."
            case .agent: "The agent reported a failure while preparing its reply."
            case .send: "The message could not be sent or its reply could not be completed."
            case .capacity: "All available reply slots were in use."
            case .card: "The answer card changed before the reply could be sent."
            case .attachment: "The attachment could not be prepared for this message."
            case .storage: "SwarmHub could not read or save local chat data."
            case .connection: "The connection to the server was interrupted."
            case .operation: "SwarmHub could not complete the requested action."
            }
        }
    }

    let id: UUID
    let date: Date
    let botID: UUID?
    let reason: Reason
}

extension AppStore {
    static let recentErrorsKey = "chat.dismissedErrors.v1"
    static let recentErrorLimit = 30

    var recentErrors: [DismissedError] {
        guard let data = defaults.data(forKey: Self.recentErrorsKey),
              let saved = try? JSONDecoder().decode([DismissedError].self, from: data) else { return [] }
        return Array(saved.prefix(Self.recentErrorLimit))
    }

    func presentError(_ detail: String, reason: DismissedError.Reason, bot: Bot? = nil) {
        errorMessage = detail
        pendingError = DismissedError(id: UUID(), date: now(), botID: bot?.id, reason: reason)
    }

    func dismissError() {
        guard let message = errorMessage else { return }
        let reason: DismissedError.Reason
        if connectionNotice != nil { reason = .connection }
        else if message.hasPrefix("Could not save") || message.hasPrefix("Could not read store.json") { reason = .storage }
        else { reason = .operation }
        let entry = pendingError ?? DismissedError(id: UUID(), date: now(), botID: nil, reason: reason)
        if persistenceEnabled {
            defaults.set(try? JSONEncoder().encode([entry] + Array(recentErrors.prefix(Self.recentErrorLimit - 1))), forKey: Self.recentErrorsKey)
        }
        errorMessage = nil
    }
}
