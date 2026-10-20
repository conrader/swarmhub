import Foundation

/// Immutable runtime data, decoded directly from the box, never from a reply fence. Shared by Mac and iOS (P5d).
public struct ManagedRecord: Codable, Equatable, Sendable {
    /// The complete admitted spec exactly as the runtime fingerprints it. Every field is kept and rendered, so the
    /// card shows what the box returned (cross-review finding 7), not a lossy subset of known keys.
    public struct Spec: Codable, Equatable, Sendable {
        public var fields: [String: JSONValue]

        public init(fields: [String: JSONValue]) { self.fields = fields }

        public init(kind: String, bot: String, intent: String, risks: [String]? = nil, argv: [String]? = nil, to: String? = nil,
                    text: String? = nil, task: String? = nil, directory: String? = nil, report: String? = nil, verify: String? = nil,
                    model: String? = nil, effort: String? = nil, order: String? = nil, fake: Bool? = nil) {
            var fields: [String: JSONValue] = ["kind": .string(kind), "bot": .string(bot), "intent": .string(intent)]
            if let risks { fields["risks"] = .array(risks.map { .string($0) }) }
            if let argv { fields["argv"] = .array(argv.map { .string($0) }) }
            let strings: [(String, String?)] = [("to", to), ("text", text), ("task", task), ("directory", directory), ("report", report),
                                                ("verify", verify), ("model", model), ("effort", effort), ("order", order)]
            for (key, value) in strings {
                if let value { fields[key] = .string(value) }
            }
            if let fake { fields["fake"] = .bool(fake) }
            self.fields = fields
        }

        public init(from decoder: Decoder) throws {
            fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(fields)
        }

        public var kind: String { fields["kind"]?.stringValue ?? "" }
        public var bot: String { fields["bot"]?.stringValue ?? "" }
        public var intent: String { fields["intent"]?.stringValue ?? "" }
        public var risks: [String]? { fields["risks"]?.arrayValue?.compactMap(\.stringValue) }
        public var argv: [String]? { fields["argv"]?.arrayValue?.compactMap(\.stringValue) }
        public var to: String? { fields["to"]?.stringValue }
        public var text: String? { fields["text"]?.stringValue }
        public var fake: Bool? { fields["fake"]?.boolValue }
    }
    public let id: String
    public let fingerprint: String
    public let gate: String
    public let status: String
    public let decider: String?
    public let spec: Spec
    public var decided_by: String? = nil
    public var decided_at: Double? = nil
    public struct RemoteBinding: Codable, Equatable, Sendable {
        public let origin: String
        public let runtime: String
        public let profile: String
        public init(origin: String, runtime: String, profile: String) {
            self.origin = origin; self.runtime = runtime; self.profile = profile
        }
    }
    public struct RemoteReceipt: Codable, Equatable, Sendable {
        public let id: String
        public let approved: Bool
        public var `protocol`: Int? = nil
        public var device: String? = nil
        public var nonce: String? = nil
        public var fingerprint: String? = nil
        public var message: String? = nil
        public init(id: String, approved: Bool, `protocol`: Int? = nil, device: String? = nil, nonce: String? = nil,
                    fingerprint: String? = nil, message: String? = nil) {
            self.id = id; self.approved = approved; self.`protocol` = `protocol`; self.device = device
            self.nonce = nonce; self.fingerprint = fingerprint; self.message = message
        }
    }
    public var remoteBinding: RemoteBinding? = nil
    public var remoteReceipt: RemoteReceipt? = nil

    /// The former memberwise initializer, public so the Mac app and its tests construct records unchanged.
    public init(id: String, fingerprint: String, gate: String, status: String, decider: String?, spec: Spec,
                decided_by: String? = nil, decided_at: Double? = nil, remoteBinding: RemoteBinding? = nil,
                remoteReceipt: RemoteReceipt? = nil) {
        self.id = id; self.fingerprint = fingerprint; self.gate = gate; self.status = status; self.decider = decider
        self.spec = spec; self.decided_by = decided_by; self.decided_at = decided_at
        self.remoteBinding = remoteBinding; self.remoteReceipt = remoteReceipt
    }

    public var awaiting: Bool { status == "awaiting-" + gate }
    public func sameOperation(as original: ManagedRecord) -> Bool {
        id == original.id && fingerprint == original.fingerprint && gate == original.gate &&
        spec == original.spec && decider == original.decider && remoteBinding == original.remoteBinding
    }
    public func confirms(_ approved: Bool, original: ManagedRecord) -> Bool {
        guard sameOperation(as: original), decided_by == original.decider, decided_at != nil else { return false }
        if remoteBinding != nil {
            guard let remoteReceipt, UUID(uuidString: remoteReceipt.id) != nil else { return false }
            return remoteReceipt.approved == approved
        }
        return approved ? ["queued", "running", "done", "failed"].contains(status) : status == "denied"
    }
}

public enum ManagedControlError: LocalizedError {
    case unavailable, invalidRecord, rejected, attemptExpired, operationGone
    case unsent(String)
    case refused(String)
    case retired(task: String, origin: String, runtime: String, reason: String)
    public var errorDescription: String? {
        switch self {
        case .unsent(let reason): reason
        case .refused(let reason): "The box refused the decision (\(reason)). You can retry or deny."
        case .retired(_, _, _, let reason): "The runtime retired this approval: \(reason)."
        case .unavailable: "Managed approval requires an authenticated SwarmHub control service at this Hermes connection. The operation remains pending."
        case .invalidRecord: "The runtime record is stale or does not match this approval."
        case .rejected: "The runtime did not confirm the decision. Refresh status before retrying."
        case .attemptExpired: "The earlier attempt expired without a recorded decision. Review the operation and choose again."
        case .operationGone: "The box no longer has this operation, so no decision was recorded. Any saved choice on this card was cleared."
        }
    }
}
