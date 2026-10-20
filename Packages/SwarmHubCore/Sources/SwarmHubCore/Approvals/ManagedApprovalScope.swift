import Foundation

/// A model-authored approval fence is a notification only: it names a task, never its content or authority.
/// Same grammar as the Mac (`ManagedApproval.parse`): ```swarmhub fences, else one whole-reply JSON object.
public enum ManagedApprovalNotice {
    public struct Item: Equatable, Sendable {
        public let task: String
        public let decider: String?
    }

    static let kinds: Set<String> = ["coding", "peer", "read", "outbound", "provision", "money", "prod", "secrets"]

    public static func parse(in text: String) -> [Item] {
        objects(in: text).compactMap { object in
            guard object["op"] as? String == "approval", let task = object["task"] as? String, DeviceApprovalWire.validTask(task),
                  let kind = object["kind"] as? String, kinds.contains(kind),
                  let gate = object["gate"] as? String, ["owner", "coordinator"].contains(gate) else { return nil }
            let decider = (object["decider"] as? String).flatMap { DeviceApprovalWire.validProfile($0) ? $0 : nil }
            return Item(task: task, decider: decider)
        }
    }

    private static func objects(in text: String) -> [[String: Any]] {
        let bodies = fences(in: text)
        if bodies.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return [] }
            return [object]
        }
        return bodies.flatMap { body -> [[String: Any]] in
            guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return [] }
            return (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
        }
    }

    private static func fences(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n"); var result: [String] = []; var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix { $0 == "`" }.count
            guard ticks >= 3, trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased() == "swarmhub" else { index += 1; continue }
            var end = index + 1
            while end < lines.count {
                let line = lines[end].trimmingCharacters(in: .whitespaces)
                if line.count >= ticks, line.allSatisfy({ $0 == "`" }) { break }
                end += 1
            }
            result.append(lines[(index + 1)..<min(end, lines.count)].joined(separator: "\n"))
            index = end + 1
        }
        return result
    }
}

/// One managed approval the app may read and decide with its device key: a box, a decider profile and a task.
public struct ManagedApprovalTarget: Hashable, Sendable {
    public let agentID: String
    public let address: String
    public let origin: String
    public let profile: String
    public let task: String
    public init(agentID: String, address: String, origin: String, profile: String, task: String) {
        self.agentID = agentID; self.address = address; self.origin = origin; self.profile = profile; self.task = task
    }
}

/// Which boxes a device-signed-only app (iOS) may ask about managed approvals. A box qualifies as a candidate only
/// after the user confirmed its operator cutover on this device (a local opt-in, so unenrolled boxes get no signed
/// reads); what is shown and decided then follows the mode the box itself reports on every read
/// (`ManagedApprovalFlow`, `DeviceApprovalChecks.deviceRequiredOnly`). Nothing here falls back to a shared-key or native path.
public enum ManagedApprovalScope {
    /// Notices are read from the newest assistant messages only.
    public static let messageLimit = 50

    public static func origin(of address: ConnectionAddress) -> String? {
        try? DeviceApprovalWire.origin(address: address.baseURL.absoluteString)
    }

    /// Origins of the given profiles opted in on this device (candidates, not proof of the box's mode), sorted and unique.
    public static func requiredOrigins(_ profiles: [AgentProfile], settings: DeviceApprovalSettings) -> [String] {
        Array(Set(profiles.compactMap { Self.origin(of: $0.address) }.filter(settings.isRequired))).sorted()
    }

    /// All origins of the given profiles that could be enrolled (valid device-approval origins), sorted and unique.
    public static func enrollableOrigins(_ profiles: [AgentProfile]) -> [String] {
        Array(Set(profiles.compactMap { Self.origin(of: $0.address) })).sorted()
    }

    /// A notice is routed to the connected profile named as its decider on the same box, else to the profile whose
    /// chat carried it when that profile is the decider or none is named. Anything else is dropped, because the box
    /// only answers a device for the operation's current decider profile.
    public static func targets(profiles: [AgentProfile], caches: [String: ChatCache], settings: DeviceApprovalSettings) -> [ManagedApprovalTarget] {
        var seen = Set<String>(), result: [ManagedApprovalTarget] = []
        let eligible = profiles.compactMap { profile -> (AgentProfile, String)? in
            guard let origin = Self.origin(of: profile.address), settings.isRequired(origin),
                  DeviceApprovalWire.validProfile(profile.address.profile) else { return nil }
            return (profile, origin)
        }
        for (source, origin) in eligible {
            let messages = (caches[source.id]?.messages ?? []).filter { $0.role == .assistant }.suffix(messageLimit)
            for item in messages.flatMap({ ManagedApprovalNotice.parse(in: $0.text) }) {
                let decider = item.decider ?? source.address.profile
                guard let match = eligible.first(where: { $0.1 == origin && $0.0.address.profile == decider }),
                      seen.insert(origin + " " + item.task).inserted else { continue }
                result.append(ManagedApprovalTarget(agentID: match.0.id, address: match.0.address.baseURL.absoluteString,
                                                    origin: origin, profile: decider, task: item.task))
            }
        }
        return result
    }
}

/// The device-signed decision sequence for apps without a native card store (iOS). Every step re-reads the box:
/// a committed receipt is adopted, never re-sent; an uncertain earlier attempt blocks a new one. Every read and the
/// challenge must report `mode: "required"` (else `ManagedControlError.notDeviceRequired`, nothing signed), and a
/// valid receipt another enrolled device committed for the same operation resolves the card (`decidedElsewhere`).
public enum ManagedApprovalFlow {
    /// Pending record for display, or the committed receipt. Never creates a nonce.
    public static func load(_ target: ManagedApprovalTarget, identity: DeviceApprovalIdentity, settings: DeviceApprovalSettings,
                            session: URLSession? = nil, timeout: TimeInterval = 15) async throws -> ManagedRecord {
        try await DeviceSignedApprovalClient.request(address: target.address, profile: target.profile, verb: "get", task: target.task,
                                                     input: nil, identity: identity, settings: settings, session: session, timeout: timeout,
                                                     checks: .deviceRequiredOnly)
    }

    /// True for a receipt whose decision was signed by a different device than `identity` (for example the Mac).
    public static func decidedElsewhere(_ record: ManagedRecord, identity: DeviceApprovalIdentity) -> Bool {
        guard let device = record.remoteReceipt?.device else { return false }
        return device != identity.keyID
    }

    /// Returns the box's receipt. Its `remoteReceipt.approved` may differ from `approved` when the box had already
    /// recorded another decision; callers report that receipt rather than retrying.
    public static func decide(_ target: ManagedApprovalTarget, reviewed: ManagedRecord, approved: Bool, identity: DeviceApprovalIdentity,
                              settings: DeviceApprovalSettings, session: URLSession? = nil, timeout: TimeInterval = 15) async throws -> ManagedRecord {
        guard reviewed.id == target.task, reviewed.decider == target.profile, reviewed.awaiting, reviewed.remoteReceipt == nil,
              let binding = reviewed.remoteBinding, binding.origin == target.origin, binding.profile == target.profile else {
            throw ManagedControlError.invalidRecord
        }
        let current = try await load(target, identity: identity, settings: settings, session: session, timeout: timeout)
        if current.remoteReceipt != nil {
            guard current.sameOperation(as: reviewed) else { throw ManagedControlError.invalidRecord }
            return current
        }
        guard current.sameOperation(as: reviewed), current.awaiting else { throw ManagedControlError.invalidRecord }
        let input = try DeviceApprovalWire.canonical(.object([
            "approved": .bool(approved), "fingerprint": .string(reviewed.fingerprint), "gate": .string(reviewed.gate),
            "binding": .object(["origin": .string(binding.origin), "runtime": .string(binding.runtime), "profile": .string(binding.profile)])]))
        let confirmed = try await DeviceSignedApprovalClient.request(address: target.address, profile: target.profile, verb: "decide",
            task: target.task, input: input, identity: identity, settings: settings, reviewed: reviewed, session: session, timeout: timeout,
            checks: .deviceRequiredOnly)
        guard confirmed.confirms(approved, original: reviewed) else { throw ManagedControlError.rejected }
        return confirmed
    }
}
