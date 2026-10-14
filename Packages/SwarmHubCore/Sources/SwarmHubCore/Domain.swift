import Foundation

public struct AgentProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var address: ConnectionAddress
    public var sessionID: String?
    public var color: String
    public init(id: String = UUID().uuidString, name: String, address: ConnectionAddress, sessionID: String? = nil, color: String = "blue") {
        self.id = id; self.name = name; self.address = address; self.sessionID = sessionID; self.color = color
    }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public init(id: String, title: String, source: String = "api_server") { self.id = id; self.title = title; self.source = source }
}

public enum TranscriptRole: String, Codable, Sendable { case user, assistant, system }
public struct TranscriptMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: TranscriptRole
    public var text: String
    public let timestamp: Date?
    public init(id: String, role: TranscriptRole, text: String, timestamp: Date? = nil) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp
    }
}

public enum TurnState: String, Codable, Sendable { case sending, streaming, interrupted, completed, cancelled, failed }
public struct PendingTurn: Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let input: String
    public var output: String
    public var runID: String?
    public var state: TurnState
    public init(id: String = UUID().uuidString, sessionID: String, input: String, output: String = "", runID: String? = nil, state: TurnState = .sending) {
        self.id = id; self.sessionID = sessionID; self.input = input; self.output = output; self.runID = runID; self.state = state
    }
}

public struct ChatCache: Codable, Sendable {
    public var messages: [TranscriptMessage]
    public var draft: String
    public var turn: PendingTurn?
    public init(messages: [TranscriptMessage] = [], draft: String = "", turn: PendingTurn? = nil) { self.messages = messages; self.draft = draft; self.turn = turn }
}

public struct ServerCapabilities: Equatable, Sendable {
    public let features: Set<String>
    public init(features: Set<String> = []) { self.features = features }
    public var sessions: Bool { features.contains("session_chat_streaming") }
    public var stop: Bool { features.contains("run_stop") }
    public var steer: Bool { features.contains("run_steer") }
    public var approvals: Bool { features.contains("run_approval_response") }
}

public struct ProfileVerification: Sendable {
    public let name: String
    public let capabilities: ServerCapabilities
    public init(name: String, capabilities: ServerCapabilities) { self.name = name; self.capabilities = capabilities }
}

public struct ApprovalItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(runID):\(requestID)" }
    public let runID: String
    public let requestID: String
    public let title: String
    public let command: String?
    public let choices: [String]
    public init(runID: String, requestID: String, title: String, command: String?, choices: [String]) {
        self.runID = runID; self.requestID = requestID; self.title = title; self.command = command; self.choices = choices
    }
    public var canApprove: Bool {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, choices.contains("once") else { return false }
        return !["***", "...", "[redacted]", "«redacted"].contains { command.lowercased().contains($0) }
    }
}

public enum ChatEvent: Equatable, Sendable {
    case started(String), delta(String), snapshot(String), status(String), approval(ApprovalItem)
    case terminal(TurnState)
}

public struct RunSnapshot: Sendable {
    public let state: TurnState?
    public let status: String
    public let approval: ApprovalItem?
    public init(state: TurnState?, status: String, approval: ApprovalItem? = nil) { self.state = state; self.status = status; self.approval = approval }
}
