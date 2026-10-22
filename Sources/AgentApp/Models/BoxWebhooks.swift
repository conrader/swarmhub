import CryptoKit
import Foundation
import Security

/// Managed webhook routines on a bot's box (`swarmctl webhook panel`, skill swarmhub-messages). The key is generated
/// on this Mac, shown once and never stored: the box receives only `sha256:<hex>` of it and checks each caller against
/// that digest, so no key crosses a model turn, a session transcript, a log or the box's disk.
struct BoxWebhook: Decodable, Equatable, Identifiable, Sendable {
    let profile: String, routine: String, url: String
    var created: Double? = nil, rotated: Double? = nil, fired: Int? = nil
    var id: String { profile + "/" + routine }
    /// The box's default URL answers only on the box until a reverse proxy and the policy's `webhook_base` expose it.
    var isLoopbackOnly: Bool { URL(string: url)?.host.map { ["127.0.0.1", "localhost", "::1", "[::1]"].contains($0) } ?? false }
}

/// `swarmctl webhook receiver status`: whether the supervised loopback receiver answers its health check.
struct WebhookReceiverStatus: Decodable, Equatable, Sendable {
    let manager: String, installed: Bool, service: String, running: Bool, listen: String, logs: String, detail: String
}

/// One answer of the app's panel call: the action's result, then the profile's routines and the receiver state.
struct WebhookPanel: Decodable, Equatable, Sendable {
    static let schemaID = "swarmhub/webhooks/1"
    struct Outcome: Decodable, Equatable, Sendable { var url: String? = nil, deleted: Bool? = nil, error: String? = nil }
    let schema: String, profile: String, action: String
    let result: Outcome?
    let webhooks: [BoxWebhook]
    let receiver: WebhookReceiverStatus

    /// Plain stdout or Hermes' `{"output", "exit_code"}` terminal wrapper; the JSON is stdout's last line, never prose.
    static func decode(_ output: String) throws -> WebhookPanel {
        guard output.utf8.count <= 1_048_576 else { throw WebhookPanelError.unreadable }
        var text = output
        if let wrapper = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
           let stdout = (wrapper["output"] ?? wrapper["stdout"]) as? String {
            if let exit = wrapper["exit_code"] as? Int, exit != 0 { throw WebhookPanelError.refusal(stdout, exit: exit) }
            text = stdout
        }
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let panel = try? JSONDecoder().decode(WebhookPanel.self, from: Data(line.utf8)), panel.schema == schemaID
        else { throw WebhookPanelError.refusal(text) }
        return panel
    }
}

enum WebhookPanelError: LocalizedError, Equatable {
    case refused(String), unreadable, busy, unavailable(String), approvalRequested, noAnswer

    /// The box's own `swarmctl: …` line when there is one (a short, key-free validation message), else a generic one.
    static func refusal(_ output: String, exit: Int? = nil) -> Self {
        let line = output.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("swarmctl: ") }
        guard let line else { return exit.map { .refused("the webhook command exited with status \($0)") } ?? .unreadable }
        return .refused(ToolEvent.redacted(String(line.dropFirst("swarmctl: ".count).prefix(300))))
    }

    var errorDescription: String? {
        switch self {
        case .refused(let reason): "The box refused: \(reason)"
        case .unreadable: "The box gave no readable answer. Is the Swarm Hub messages skill installed for this agent?"
        case .busy: "This agent (or the agent that manages its box) is busy. Try again when its chat is idle."
        case .unavailable(let reason): reason
        case .approvalRequested: "The box asked for approval to run the webhook command, so nothing ran."
        case .noAnswer: "The command did not report back. Nothing is confirmed; refresh to see the current state."
        }
    }
}

/// What the panel asks the box to do.
enum WebhookAction: Equatable, Sendable {
    case list, create(String), rotate(String), delete(String), startReceiver

    var verb: String {
        switch self {
        case .list: "list"
        case .create: "register"
        case .rotate: "rotate"
        case .delete: "delete"
        case .startReceiver: "receiver-install"
        }
    }
    var routine: String? {
        switch self {
        case .create(let name), .rotate(let name), .delete(let name): name
        case .list, .startReceiver: nil
        }
    }
    var needsKey: Bool { if case .create = self { true } else if case .rotate = self { true } else { false } }
}

enum WebhookKey {
    /// 32 random bytes, base64url without padding (43 characters).
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL
        }
        return Data(bytes).base64URL
    }

    /// What the box stores and checks callers against: `sha256:` and the lowercase hex digest of the key's UTF-8.
    static func digest(_ key: String) -> String {
        "sha256:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum WebhookCommand {
    /// Profile and routine names the box accepts (`NAME`, at most 64), without a leading dot or dash.
    static func validName(_ name: String) -> Bool {
        name.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z"#, options: .regularExpression) != nil
    }

    /// The argv after `swarmctl`; nil for a name the box would refuse or a key action without its digest.
    static func arguments(profile: String, action: WebhookAction, keyHash: String? = nil) -> [String]? {
        guard validName(profile) else { return nil }
        var words = ["webhook", "panel", profile, action.verb]
        if let routine = action.routine {
            guard validName(routine) else { return nil }
            words.append(routine)
        }
        if action.needsKey {
            guard let keyHash, keyHash.range(of: #"\Asha256:[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { return nil }
            words += ["--key-hash", keyHash]
        }
        return words
    }

    /// One terminal line in the running agent's shell. Every word is validated above, so none needs quoting, and the
    /// skill path keeps its `~/` for the shell to expand.
    static func line(script: String, arguments: [String]) -> String {
        (["python3", "-B", script] + arguments).joined(separator: " ")
    }

    /// The exact shape `line` produces, so the Hermes stream keeps this command for pairing (`HermesBackend.nativeTool`).
    static func matches(_ command: String) -> Bool {
        command.range(of: #"\Apython3 -B ~/\.hermes/(profiles/[A-Za-z0-9_][A-Za-z0-9_.-]*/)?skills/[A-Za-z0-9_-]+/swarmhub-messages/scripts/swarmctl webhook panel [A-Za-z0-9_][A-Za-z0-9_.-]{0,63} (list|receiver-install|delete [A-Za-z0-9_][A-Za-z0-9_.-]{0,63}|(register|rotate) [A-Za-z0-9_][A-Za-z0-9_.-]{0,63} --key-hash sha256:[0-9a-f]{64})\z"#,
                      options: .regularExpression) != nil
    }
}

/// Pairs the panel command's terminal result to its start by the server's tool call id, like `UpdaterStatusCall`.
struct WebhookPanelCall {
    let command: String
    private var callID: String?
    private(set) var outcome: Result<WebhookPanel, WebhookPanelError>?

    init(command: String) { self.command = command }

    mutating func consume(_ tool: ToolEvent) {
        guard ["terminal", "shell", "execute", "bash"].contains(tool.name), outcome == nil else { return }
        if tool.phase == .started, tool.command == command { callID = tool.callID; return }
        guard let expected = callID, tool.callID == expected, tool.phase == .completed || tool.phase == .failed else { return }
        callID = nil
        do { outcome = .success(try WebhookPanel.decode(tool.result ?? "")) }
        catch let error as WebhookPanelError { outcome = .failure(error) }
        catch { outcome = .failure(.unreadable) }
    }

    func panel() throws -> WebhookPanel {
        guard let outcome else { throw WebhookPanelError.noAnswer }
        return try outcome.get()
    }
}
