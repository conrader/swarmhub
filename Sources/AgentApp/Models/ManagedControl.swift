import Foundation
import SwarmHubCore

/// The record type and its errors live in SwarmHubCore (P5d); a card for the Mac is built here.
extension ManagedRecord {
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
        request.routeNote = "Runtime operation verified\(remoteBinding.map { " at " + $0.origin } ?? " locally"). Decision binds fingerprint \(fingerprint) and gate \(gate)."
        return request
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
