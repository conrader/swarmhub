import Foundation
import CryptoKit

public struct TeamEnvelope: Codable, Equatable, Sendable {
    public var operationID: String
    public var taskID: String
    public var conversationID: UUID
    public var recipient: TeamIdentity
    public var replyToID: String?
    public var kind: String
    public var payload: String
    public init(operationID: String, taskID: String, conversationID: UUID, recipient: TeamIdentity,
                replyToID: String?, kind: String, payload: String) {
        self.operationID = operationID; self.taskID = taskID; self.conversationID = conversationID
        self.recipient = recipient; self.replyToID = replyToID; self.kind = kind; self.payload = payload
    }
    public var fingerprint: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Local intent and observations are separate. A crash after dispatch never proves that a remote request was absent.
public struct TeamDelivery: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, dispatching, accepted, running, completed, failed, uncertain, cancelledBeforeSend
        public var label: String {
            switch self {
            case .queued: "Waiting to continue"
            case .dispatching: "Dispatching"
            case .accepted: "Accepted by server"
            case .running: "Running remotely"
            case .completed: "Remote reply finished"
            case .failed: "Failed"
            case .uncertain: "Uncertain — check server"
            case .cancelledBeforeSend: "Cancelled before sending"
            }
        }
    }
    public struct Event: Codable, Equatable, Sendable {
        public var state: State
        public var at: Date
    }
    public var envelope: TeamEnvelope
    public var fingerprint: String
    public var sessionID: String
    public var runID: String?
    public var submissionStarted: Bool?
    public var replyID: UUID
    public var events: [Event]
    public var state: State { events.last?.state ?? .queued }
    public init(envelope: TeamEnvelope, sessionID: String, replyID: UUID, at date: Date) throws {
        self.envelope = envelope; fingerprint = try envelope.fingerprint
        self.sessionID = sessionID; self.replyID = replyID; events = [.init(state: .queued, at: date)]
    }
    public mutating func record(_ state: State, at date: Date) {
        guard self.state != state else { return }
        events.append(.init(state: state, at: date))
    }
}

/// Evidence supplied by an agent is a claim until a human confirms its checks. Run completion alone is not verification.
public struct TeamEvidence: Codable, Equatable, Sendable {
    public var source: String
    public var observation: String
    public init(source: String, observation: String) { self.source = source; self.observation = observation }
}
