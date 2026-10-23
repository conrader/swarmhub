import CryptoKit
import Foundation

/// Off-app alerts on a server (`swarmctl alerts panel`, skill swarmhub-messages 1.4.12+): the box sends finished
/// routines, code jobs, reports and webhook wakes to ntfy or email while SwarmHub is closed or its user is away.
/// The settings travel sealed to the box's own key (`AlertSeal`), so the ntfy token and SMTP password never cross a
/// model turn, a session transcript or a log in clear; on the Mac they stay in the Keychain.
struct BoxAlertsPanel: Decodable, Equatable, Sendable {
    static let schemaID = "swarmhub/alerts/1"
    struct Outcome: Decodable, Equatable, Sendable {
        var saved: Bool? = nil, error: String? = nil, removed: Bool? = nil, manager: String? = nil
        var sinks: [String: String]? = nil
    }
    struct Summary: Decodable, Equatable, Sendable {
        let configured: Bool, enabled: Bool, window: Bool, sinks: [String]
    }
    struct Service: Decodable, Equatable, Sendable {
        let manager: String, installed: Bool, service: String, running: Bool, detail: String
        var logs: String? = nil
        var lastError: String? = nil, lastErrorAt: Double? = nil, lastSentAt: Double? = nil, presenceUntil: Double? = nil
        var pending: Int? = nil
        enum CodingKeys: String, CodingKey {
            case manager, installed, service, running, detail, logs, pending
            case lastError = "last_error", lastErrorAt = "last_error_at", lastSentAt = "last_sent_at", presenceUntil = "presence_until"
        }
    }
    let schema: String, action: String
    let result: Outcome?
    let config: Summary
    let service: Service
    let boxKey: String
    enum CodingKeys: String, CodingKey { case schema, action, result, config, service, boxKey = "box_key" }

    /// Plain stdout or Hermes' `{"output", "exit_code"}` terminal wrapper; the JSON is stdout's last line.
    static func decode(_ output: String) throws -> BoxAlertsPanel {
        guard output.utf8.count <= 1_048_576 else { throw BoxAlertsError.unreadable }
        var text = output
        if let wrapper = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
           let stdout = (wrapper["output"] ?? wrapper["stdout"]) as? String {
            if let exit = wrapper["exit_code"] as? Int, exit != 0 { throw BoxAlertsError.refusal(stdout, exit: exit) }
            text = stdout
        }
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let panel = try? JSONDecoder().decode(BoxAlertsPanel.self, from: Data(line.utf8)), panel.schema == schemaID
        else { throw BoxAlertsError.refusal(text) }
        return panel
    }
}

enum BoxAlertsError: LocalizedError, Equatable {
    case refused(String), unreadable, noRunner, noBoxKey, sealFailed

    /// The box's own `swarmctl: …` line (short, secret-free), else a generic reason.
    static func refusal(_ output: String, exit: Int? = nil) -> Self {
        let line = output.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("swarmctl: ") }
        guard let line else { return exit.map { .refused(AlertsCopy.exited($0)) } ?? .unreadable }
        return .refused(ToolEvent.redacted(String(line.dropFirst("swarmctl: ".count).prefix(300))))
    }

    var errorDescription: String? {
        switch self {
        case .refused(let reason): AlertsCopy.refused(reason)
        case .unreadable: AlertsCopy.unreadable
        case .noRunner: AlertsCopy.noRunner
        case .noBoxKey: AlertsCopy.noBoxKey
        case .sealFailed: AlertsCopy.sealFailed
        }
    }
}

/// What the pane asks the box to do.
enum BoxAlertsAction: Equatable, Sendable {
    case status, configure(String), test, install, uninstall

    var verb: String {
        switch self {
        case .status: "status"
        case .configure: "configure"
        case .test: "test"
        case .install: "install"
        case .uninstall: "uninstall"
        }
    }
}

/// The settings SwarmHub keeps per server (UserDefaults, no secret). The token and the password are Keychain items
/// (`AppStore.alertSecretAccount`), added only to the sealed copy that goes to the box.
struct AlertSettings: Codable, Equatable, Sendable {
    enum Security: String, Codable, CaseIterable, Sendable { case starttls, ssl, none }
    var enabled = true
    /// Hold alerts outside the box policy's reporting window (08:00–23:00 by default) and send one digest when it opens.
    var window = true
    var ntfyOn = true
    var ntfyURL = ""
    var emailOn = false
    var emailHost = "", emailPort = 587, emailSecurity = Security.starttls, emailUser = "", emailFrom = "", emailTo = ""

    var hasSink: Bool { (ntfyOn && !ntfyURL.trimmingCharacters(in: .whitespaces).isEmpty) || (emailOn && !emailHost.isEmpty) }

    /// The box's settings JSON (`swarm_alerts.validate`), secrets included: only ever sealed, never stored or logged.
    func boxJSON(ntfyToken: String, emailPassword: String) -> Data {
        var object: [String: Any] = ["v": 1, "enabled": enabled, "window": window]
        if ntfyOn, !ntfyURL.isEmpty {
            var ntfy: [String: Any] = ["url": ntfyURL.trimmingCharacters(in: .whitespaces)]
            if !ntfyToken.isEmpty { ntfy["token"] = ntfyToken }
            object["ntfy"] = ntfy
        }
        if emailOn, !emailHost.isEmpty {
            var email: [String: Any] = ["host": emailHost.trimmingCharacters(in: .whitespaces), "port": emailPort,
                                        "security": emailSecurity.rawValue, "from": emailFrom, "to": emailTo]
            if !emailUser.isEmpty { email["user"] = emailUser }
            if !emailPassword.isEmpty { email["password"] = emailPassword }
            object["email"] = email
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// Seals the settings to the box's X25519 key (`swarm_alerts_seal.py`): "v1." + base64url(ephemeral public ‖
/// ciphertext ‖ 16-byte tag). Keys: HKDF-SHA256(salt: ephemeral public ‖ box public, info: "swarmhub-alerts-seal-v1",
/// 64 bytes); key stream block i = HMAC-SHA256(first 32, i as UInt64 big-endian); tag = HMAC-SHA256(last 32,
/// ephemeral public ‖ ciphertext), first 16 bytes.
enum AlertSeal {
    static let info = Data("swarmhub-alerts-seal-v1".utf8)

    static func seal(_ plaintext: Data, to boxKey: String,
                     ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) throws -> String {
        guard let raw = unpadded(boxKey), raw.count == 32 else { throw BoxAlertsError.noBoxKey }
        let box = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let mine = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: box)
        let keys = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: mine + raw, sharedInfo: info, outputByteCount: 64)
        let bytes = keys.withUnsafeBytes { Data($0) }
        let encryption = SymmetricKey(data: bytes.prefix(32)), authentication = SymmetricKey(data: bytes.suffix(32))
        var stream = Data()
        var counter: UInt64 = 0
        while stream.count < plaintext.count {
            stream += Data(HMAC<SHA256>.authenticationCode(for: withUnsafeBytes(of: counter.bigEndian) { Data($0) }, using: encryption))
            counter += 1
        }
        let body = Data(zip(plaintext, stream).map { $0 ^ $1 })
        let tag = Data(HMAC<SHA256>.authenticationCode(for: mine + body, using: authentication)).prefix(16)
        return "v1." + (mine + body + tag).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// base64url without padding (the box's `box_key`).
    static func unpadded(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}

enum AlertsCommand {
    /// The argv after `swarmctl`; nil for a sealed blob the box would refuse.
    static func arguments(_ action: BoxAlertsAction) -> [String]? {
        guard case .configure(let blob) = action else { return ["alerts", "panel", action.verb] }
        guard blob.range(of: #"\Av1\.[A-Za-z0-9_-]{66,6000}\z"#, options: .regularExpression) != nil else { return nil }
        return ["alerts", "panel", "configure", blob]
    }

    /// The exact shape `WebhookCommand.line` produces for these arguments, so the Hermes stream keeps it for pairing.
    static func matches(_ command: String) -> Bool {
        command.range(of: #"\Apython3 -B ~/\.hermes/(profiles/[A-Za-z0-9_][A-Za-z0-9_.-]*/)?skills/[A-Za-z0-9_-]+/swarmhub-messages/scripts/swarmctl alerts panel (status|test|install|uninstall|configure v1\.[A-Za-z0-9_-]{66,6000})\z"#,
                      options: .regularExpression) != nil
    }
}

/// Pairs the alerts command's terminal result to its start by the server's tool call id, like `WebhookPanelCall`.
struct BoxAlertsCall: BoxCommandCall {
    let command: String
    private var callID: String?
    private(set) var outcome: Result<BoxAlertsPanel, BoxAlertsError>?

    init(command: String) { self.command = command }

    var answered: Bool { outcome != nil }

    mutating func consume(_ tool: ToolEvent) {
        guard ["terminal", "shell", "execute", "bash"].contains(tool.name), outcome == nil else { return }
        if tool.phase == .started, tool.command == command { callID = tool.callID; return }
        guard let expected = callID, tool.callID == expected, tool.phase == .completed || tool.phase == .failed else { return }
        callID = nil
        do { outcome = .success(try BoxAlertsPanel.decode(tool.result ?? "")) }
        catch let error as BoxAlertsError { outcome = .failure(error) }
        catch { outcome = .failure(.unreadable) }
    }

    func panel() throws -> BoxAlertsPanel {
        guard let outcome else { throw WebhookPanelError.noAnswer }
        return try outcome.get()
    }
}
