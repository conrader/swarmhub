#if DEBUG
import Foundation
import CryptoKit
import Darwin

/// Same payload and receipt contract as sim.run.RecordingSandbox. No network or process execution.
@MainActor final class QARecorder {
    static let tools: Set<String> = ["email.send", "slack.send", "whatsapp.send", "connected.read", "qa_wait", "qa_approval"]
    let url: URL
    private var seen: [String: String] = [:]
    init(directory: URL) throws {
        url = directory.appending(path: "sink.jsonl")
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw QAError.refused }
            let data = try Data(contentsOf: url)
            for line in data.split(separator: 10) {
                let row = try JSONDecoder().decode(ComposioValue.self, from: Data(line))
                guard let id = row["attempt_id"].string, let hash = row["payload_sha256"].string,
                      seen[id] == nil || seen[id] == hash else { throw QAError.refused }
                seen[id] = hash
            }
        } else { try QAMode.writePrivate(Data(), to: url) }
    }
    func record(resource: String, tool: String, payload: ComposioValue, attempt: String) throws -> ComposioValue {
        do {
            guard QAPolicy.name(resource), Self.tools.contains(tool), attempt.hasPrefix("QA-"), QAPolicy.identifier(attempt) else { throw QAError.refused }
            try QAPolicy.fields(payload, allowed: ["marker", "recipient", "body", "account"], required: ["marker", "account"])
            guard payload["marker"] == .string(QAPolicy.marker), payload["account"] == .string("QA-sandbox"),
                  [ComposioValue.null, .string("a@example.invalid"), .string("b@example.invalid"), .string("QA-sink")].contains(payload["recipient"]),
                  [ComposioValue.null, .string("[QA-TEST] A"), .string("[QA-TEST] B")].contains(payload["body"]) else { throw QAError.refused }
            // Match Python json.dumps(..., sort_keys=True) for the closed, ASCII-only payload schema.
            let canonical = try Self.canonical(.array([.string(resource), .string(tool), payload]))
            let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen[attempt] == nil || seen[attempt] == hash else { throw QAError.refused }
            let row: ComposioValue = .object(["at": .string(ISO8601DateFormatter().string(from: .now)),
                "tool": .string(tool), "resource": .string(resource), "attempt_id": .string(attempt),
                "payload": payload, "payload_sha256": .string(hash), "duplicate": .bool(seen[attempt] != nil),
                "simulated": .bool(true), "delivered": .bool(false)])
            try append(row, to: url)
            seen[attempt] = hash
            return row
        } catch {
            let refused = url.deletingLastPathComponent().appending(path: "sink.refused.jsonl")
            if !FileManager.default.fileExists(atPath: refused.path) { try QAMode.writePrivate(Data(), to: refused) }
            try append(.object(["outcome": .string("refused"), "reason": .string("outside QA sandbox allowlist")]), to: refused)
            throw error
        }
    }
    private static func canonical(_ value: ComposioValue) throws -> String {
        switch value {
        case .object(let object):
            return "{" + (try object.keys.sorted().map { try ComposioValue.string($0).text() + ": " + canonical(object[$0]!) }).joined(separator: ", ") + "}"
        case .array(let array): return "[" + (try array.map(canonical)).joined(separator: ", ") + "]"
        default: return try value.text()
        }
    }
    private func append(_ row: ComposioValue, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { throw QAError.blocked }; defer { close(fd) }
        let data = Data((try row.text() + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw QAError.blocked }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw QAError.blocked }
    }
}
#endif
