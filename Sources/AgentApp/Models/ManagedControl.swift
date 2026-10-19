import Foundation

/// Immutable runtime data, decoded directly from swarmctl, never from a reply fence.
struct ManagedRecord: Codable, Equatable, Sendable {
    /// The complete admitted spec exactly as the runtime fingerprints it. Every field is kept and rendered, so the
    /// card shows what `control get` returned (cross-review finding 7), not a lossy subset of known keys.
    struct Spec: Codable, Equatable, Sendable {
        var fields: [String: JSONValue]

        init(fields: [String: JSONValue]) { self.fields = fields }

        init(kind: String, bot: String, intent: String, risks: [String]? = nil, argv: [String]? = nil, to: String? = nil,
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

        init(from decoder: Decoder) throws {
            fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(fields)
        }

        var kind: String { fields["kind"]?.stringValue ?? "" }
        var bot: String { fields["bot"]?.stringValue ?? "" }
        var intent: String { fields["intent"]?.stringValue ?? "" }
        var risks: [String]? { fields["risks"]?.arrayValue?.compactMap(\.stringValue) }
        var argv: [String]? { fields["argv"]?.arrayValue?.compactMap(\.stringValue) }
        var to: String? { fields["to"]?.stringValue }
        var text: String? { fields["text"]?.stringValue }
        var fake: Bool? { fields["fake"]?.boolValue }
    }
    let id: String
    let fingerprint: String
    let gate: String
    let status: String
    let decider: String?
    let spec: Spec
    var decided_by: String? = nil
    var decided_at: Double? = nil

    var awaiting: Bool { status == "awaiting-" + gate }
    func request(botID: UUID) throws -> ApprovalRequest {
        guard awaiting, ManagedApproval.validTask(id) != nil,
              ["owner", "coordinator"].contains(gate), let decider,
              ManagedApproval.profileName(decider) != nil, fingerprint.count == 64 else { throw ManagedControlError.invalidRecord }
        // JSON preserves exact argv boundaries, recipient, content, verifier, model, risks and every other
        // fingerprinted field (speculative, origin, parent, request, …).
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let operation = String(decoding: try encoder.encode(spec.fields), as: UTF8.self)
        let notice = ManagedApproval(task: id, kind: spec.kind, gate: gate, decider: decider, bot: spec.bot,
                                     intent: spec.intent, summary: operation, risks: spec.risks ?? [], draft: spec.text)
        var request = notice.request(botID: botID, profile: decider)
        request.command = operation
        request.managedRecord = self
        request.routeNote = "Runtime operation verified locally. Decision binds fingerprint \(fingerprint) and gate \(gate)."
        return request
    }
    func confirms(_ approved: Bool, original: ManagedRecord) -> Bool {
        id == original.id && fingerprint == original.fingerprint && gate == original.gate &&
        decided_by == original.decider && decided_at != nil &&
        (approved ? ["queued", "running", "done", "failed"].contains(status) : status == "denied")
    }
}

extension JSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }
}

enum ManagedControlError: LocalizedError {
    case unavailable, invalidRecord, rejected
    var errorDescription: String? {
        switch self {
        case .unavailable: "Managed approval requires SwarmHub's local control interface on the runtime host. Remote notifications cannot authorize an operation."
        case .invalidRecord: "The runtime record is stale or does not match this approval."
        case .rejected: "The runtime did not confirm the decision. Refresh status before retrying."
        }
    }
}

enum ManagedLocalControl {
    /// Direct local subprocess; no shell, model, source auth or Hermes modifications. `home` is the account's home
    /// (tests inject a temporary one with the shipped scripts installed).
    static func request(address: String, profile: String, verb: String, task: String, input: Data?,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> ManagedRecord {
        guard let host = URL(string: address)?.host, ["localhost", "127.0.0.1", "::1"].contains(host),
              ManagedApproval.profileName(profile) != nil, ManagedApproval.validTask(task) != nil else { throw ManagedControlError.unavailable }
        return try await Task.detached {
            let root = home.appending(path: ".hermes")
            let profileRoot = profile == "default" ? root : root.appending(path: "profiles/\(profile)")
            let control = profileRoot.appending(path: "skills/swarmhub/swarmhub-messages/scripts/swarmctl")
            guard FileManager.default.fileExists(atPath: control.path) else { throw ManagedControlError.unavailable }
            let process = Process(), output = Pipe(), incoming = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", control.path, "control", verb, task] + (verb == "decide" ? [profile] : [])
            process.environment = ["HOME": home.path, "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                                   "PYTHONDONTWRITEBYTECODE": "1", "HERMES_HOME": profileRoot.path]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = incoming
            try process.run()
            if let input { try incoming.fileHandleForWriting.write(contentsOf: input) }
            try incoming.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ManagedControlError.rejected }
            return try JSONDecoder().decode(ManagedRecord.self, from: data)
        }.value
    }
}
