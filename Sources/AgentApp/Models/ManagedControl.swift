import Foundation

/// Immutable runtime data, decoded directly from swarmctl, never from a reply fence.
struct ManagedRecord: Codable, Equatable, Sendable {
    struct Spec: Codable, Equatable, Sendable {
        let kind: String
        let bot: String
        let intent: String
        var risks: [String]? = nil
        var argv: [String]? = nil
        var to: String? = nil
        var text: String? = nil
        var task: String? = nil
        var directory: String? = nil
        var report: String? = nil
        var verify: String? = nil
        var model: String? = nil
        var effort: String? = nil
        var order: String? = nil
        var fake: Bool? = nil
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
        // JSON preserves exact argv boundaries, recipient, content, verifier, model and risks.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let operation = String(decoding: try encoder.encode(spec), as: UTF8.self)
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
    /// Direct local subprocess; no shell, model, source auth or Hermes modifications.
    static func request(address: String, profile: String, verb: String, task: String, input: Data?) async throws -> ManagedRecord {
        guard let host = URL(string: address)?.host, ["localhost", "127.0.0.1", "::1"].contains(host),
              ManagedApproval.profileName(profile) != nil, ManagedApproval.validTask(task) != nil else { throw ManagedControlError.unavailable }
        return try await Task.detached {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let root = home.appending(path: ".hermes")
            let profileRoot = profile == "default" ? root : root.appending(path: "profiles/\(profile)")
            let control = profileRoot.appending(path: "skills/swarmhub/swarmhub-messages/scripts/swarmctl")
            guard FileManager.default.fileExists(atPath: control.path) else { throw ManagedControlError.unavailable }
            let process = Process(), output = Pipe(), incoming = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", control.path, "control", verb, task] + (verb == "decide" ? [profile] : [])
            process.environment = ["HOME": home.path, "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                                   "PYTHONDONTWRITEBYTECODE": "1", "HERMES_HOME": profile == "default" ? root.path : root.appending(path: "profiles/\(profile)").path]
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
