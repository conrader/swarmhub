import Foundation
import Darwin

/// Gap closures after live pass 4 (P02/P06/P07): what the app knows about the host-local managed control plane
/// (`swarmctl` in the swarmhub-messages skill). The app never runs `swarmctl` itself: a bot presents a managed action
/// in a ```` ```swarmhub ```` fence, the app shows a real approval card, and the decision goes back as the deciding
/// bot's own turn, because `swarmctl decide` accepts a decision only from the deciding profile's gateway.

/// A managed action awaiting a decision, as the bot presents it: `{"op":"approval","task":"task.…","kind":"outbound",
/// "gate":"coordinator","decider":"jarvis","bot":"infra","intent":"…","summary":"…","risks":[],"draft":"…"}`.
struct ManagedApproval: Equatable, Sendable {
    let task: String; let kind: String; let gate: String
    let decider: String?; let bot: String?; let intent: String; let summary: String; let risks: [String]; let draft: String?

    static let actionKindPrefix = "managed."
    static let kinds: Set<String> = ["coding", "peer", "read", "outbound", "provision", "money", "prod", "secrets"]

    var actionKind: String { Self.actionKindPrefix + kind }
    var title: String { "\(kind.capitalized) action awaits the \(gate): \(intent)" }
    var detail: String {
        var line = summary.isEmpty ? "Managed \(kind) action" : summary
        if let bot { line += " · submitted by \(bot)" }
        if !risks.isEmpty { line += " · risks: \(risks.joined(separator: ", "))" }
        return line + " · \(task)"
    }
    /// The task id's 32 hex digits are a UUID, so a redelivered fence maps to the same card; other ids get a fresh one
    /// and are deduplicated by `requestID`.
    var cardID: UUID {
        let hex = task.hasPrefix("task.") ? String(task.dropFirst(5)) : task
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return UUID() }
        let parts = [8, 4, 4, 4, 12]; var rest = Substring(hex); var groups: [String] = []
        for length in parts { groups.append(String(rest.prefix(length))); rest = rest.dropFirst(length) }
        return UUID(uuidString: groups.joined(separator: "-")) ?? UUID()
    }

    /// What the deciding bot runs, exactly, from its swarmhub-messages skill folder (its own gateway sets HERMES_HOME).
    static func decideCommand(task: String, actor: String, approved: Bool) -> String {
        "scripts/swarmctl decide \(task) \(actor) \(approved ? "approve" : "deny")"
    }
    /// The turn SwarmHub sends to the deciding bot when the user decides on the card.
    static func decisionTurn(task: String, actor: String, approved: Bool, title: String) -> String {
        "[SwarmHub approval decision] The user chose to \(approved ? "approve" : "deny") \"\(title)\". Run exactly, from your " +
        "swarmhub-messages skill folder: `\(decideCommand(task: task, actor: actor, approved: approved))` and reply with its " +
        "output in one line. Do not run anything else for this task."
    }

    func request(botID: UUID?, profile: String?) -> ApprovalRequest {
        var request = ApprovalRequest(id: cardID, title: title, summary: detail, draft: draft,
                                      command: Self.decideCommand(task: task, actor: decider ?? gate, approved: true))
        request.requestID = task; request.botID = botID; request.profile = profile; request.actionKind = actionKind
        request.rule = "Managed action · gate \(gate)"
        request.routeNote = "Decided by \(decider ?? "the \(gate)") from its own gateway; SwarmHub sends your choice as that bot's turn."
        return request
    }

    static func validTask(_ value: Any?) -> String? {
        guard let value = value as? String, value.range(of: "^task\\.[A-Za-z0-9_.-]{1,80}\\z", options: .regularExpression) != nil else { return nil }
        return value
    }
    static func profileName(_ value: Any?) -> String? {
        guard let value = value as? String, value.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,80}\\z", options: .regularExpression) != nil else { return nil }
        return value
    }
    private static func text(_ value: Any?, limit: Int = 2000) -> String {
        String((value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// Every approval block in a reply, in order; blocks with an invalid task, kind or gate are ignored.
    static func parse(in text: String) -> [ManagedApproval] {
        var found: [ManagedApproval] = []
        for fence in SwarmhubBlock.fences(in: text) {
            guard let data = fence.body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for object in objects where object["op"] as? String == "approval" {
                guard let task = validTask(object["task"]), let kind = object["kind"] as? String, kinds.contains(kind),
                      let gate = object["gate"] as? String, ["owner", "coordinator"].contains(gate) else { continue }
                let risks = ((object["risks"] as? [String]) ?? []).filter { ["money", "prod", "secrets"].contains($0) }
                let draft = Self.text(object["draft"], limit: 32000)
                found.append(ManagedApproval(task: task, kind: kind, gate: gate, decider: profileName(object["decider"]), bot: profileName(object["bot"]),
                                             intent: Self.text(object["intent"], limit: 200), summary: Self.text(object["summary"], limit: 500),
                                             risks: risks, draft: draft.isEmpty ? nil : draft))
            }
        }
        return found
    }
}

extension ApprovalRequest {
    /// A card for a host-local managed action (never a Hermes/OpenClaw tool approval).
    var isManaged: Bool { actionKind.hasPrefix(ManagedApproval.actionKindPrefix) }
}

/// P07 gap: Send on a draft card submits the exact draft as a managed outbound record instead of posting "Send it".
/// The spec is composed here so the bot copies it verbatim. Every app draft record is FAKE.
enum ManagedOutbound {

    /// One stable intent per card, so the same Send is admitted once (swarmctl's idempotent admission).
    static func intent(sourceID: UUID, index: Int) -> String { "draft-\(sourceID.uuidString.lowercased())-\(index)" }

    static func spec(draft: DraftCard, bot: String, intent: String) -> String {
        var text = draft.body
        if let subject = draft.subject, !subject.isEmpty { text = "Subject: \(subject)\n\n" + text }
        let object: [String: Any] = ["bot": bot, "kind": "outbound", "intent": intent, "to": draft.to ?? "<recipient named in this thread>",
                                     "text": text, "fake": true]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func instruction(draft: DraftCard, bot: String, intent: String) -> String {
        """
        [SwarmHub draft send] Submit this draft as a managed outbound record and do nothing else with it; never send it \
        yourself. From your swarmhub-messages skill folder, run exactly:
        scripts/swarmctl submit <<'SWARMHUB_DRAFT'
        \(spec(draft: draft, bot: bot, intent: intent))
        SWARMHUB_DRAFT
        \(draft.to == nil ? "Replace only the recipient placeholder with the recipient this draft names. " : "")\
        Read the returned record with scripts/swarmctl status. Report its task id and actual status. \
        Show an approval block only if that record is awaiting a decision; never invent a pending approval. \
        This record is FAKE: it is journaled and never sent. Keep fake set to true.
        """
    }
}

/// P06 gap: a bot asks for a user secret with `{"op":"secret_request","name":"openai-key","reason":"…"}`; the app opens
/// its secret-entry sheet and answers with the path of a 0600 file, never the value.
struct SecretRequest: Equatable, Sendable, Identifiable {
    let name: String; let reason: String
    var id: String { name }

    static func validName(_ value: String) -> String? {
        value.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,63}\\z", options: .regularExpression) == nil ? nil : value
    }

    static func parse(in text: String) -> [SecretRequest] {
        var found: [SecretRequest] = []
        for fence in SwarmhubBlock.fences(in: text) {
            guard let data = fence.body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for object in objects where object["op"] as? String == "secret_request" {
                guard let name = (object["name"] as? String).flatMap(validName) else { continue }
                found.append(SecretRequest(name: name, reason: String((object["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))))
            }
        }
        return found
    }
}

/// The sheet's subject: which bot and chat asked, and for what.
struct SecretRequestPrompt: Identifiable, Equatable {
    let id = UUID(); let botID: UUID; let conversationID: UUID; let request: SecretRequest
}

enum SecretFileError: LocalizedError {
    case invalidName, empty, tooLarge, notWritten
    var errorDescription: String? {
        switch self {
        case .invalidName: "The secret needs a short file name (letters, digits, . _ -)."
        case .empty: "The secret is empty."
        case .tooLarge: "The secret is larger than 64 KB."
        case .notWritten: "The secret file could not be created."
        }
    }
}

/// Writes a secret to `<Application Support>/SwarmHub/secrets/<name>` with mode 0600 (folder 0700) and returns the
/// path. The value is never logged, shown or kept in the store; only the path travels to the bot.
enum SecretFileWriter {
    static let limit = 65536

    static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appending(path: AppConstants.name).appending(path: "secrets")
    }

    @discardableResult static func write(_ secret: String, name: String, in folder: URL? = nil) throws -> URL {
        guard let name = SecretRequest.validName(name) else { throw SecretFileError.invalidName }
        var value = secret
        if value.hasSuffix("\n") { value.removeLast() }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SecretFileError.empty }
        guard value.utf8.count <= limit else { throw SecretFileError.tooLarge }
        let folder = folder ?? defaultFolder
        if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw SecretFileError.notWritten }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let url = folder.appending(path: name)
        // Write a fresh inode at its final mode, then rename over the destination. Existing symlinks/hardlinks and
        // world-readable files cannot redirect the write or expose the replacement value.
        let temporary = folder.appending(path: ".intake-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw SecretFileError.notWritten }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw SecretFileError.notWritten }
        try Data(value.utf8).withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw SecretFileError.empty }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SecretFileError.notWritten }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0, Darwin.rename(temporary.path, url.path) == 0 else { throw SecretFileError.notWritten }
        return url
    }

    /// What the bot is told: the path and the rules, never the value.
    static func message(for request: SecretRequest, at url: URL) -> String {
        "Secret `\(request.name)` is stored at \(url.path) (mode 0600, readable by this account only). Use only the path, " +
        "on this Mac. A remote provisioner cannot read this path: request intake on that host before provisioning. " +
        "The value is never shown in chat and never sent anywhere by SwarmHub."
    }
}
