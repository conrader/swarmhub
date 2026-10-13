import Foundation

/// Cached or fetched transcript entries → bundle messages and rename events (port of `map_entries`, same allowlist and
/// branch order). Deliberate differences from the script (briefs/P10.md P10a 4): `fromAgent`/`toAgent` present but
/// `null` count as absent; non-string `content`/`text` is empty; `seq` must be an integer JSON number and `id` a string;
/// drops are also counted per kind and card or event type.
struct GrokEntryMapper {
    /// Roster id → raw roster name (`r.get("name") or "Grok bot"`), redacted where it is used.
    let names: [String: String]
    /// The conversation's already-redacted name.
    let botName: String

    func map(_ entries: [JSONValue], redact: inout GrokRedactor, stats: inout GrokBundleV1.Statistics)
        -> (messages: [GrokBundleV1.Message], events: [GrokBundleV1.Event]) {
        var messages: [(Int, GrokBundleV1.Message)] = [], events: [(Int, GrokBundleV1.Event)] = []
        func drop(_ key: String, cards: Bool = false, event: Bool = false) {
            if cards { stats.cardsDropped += 1 } else if event { stats.eventsDropped += 1 } else { stats.toolEntriesDropped += 1 }
            stats.droppedByKind[key, default: 0] += 1
        }
        for (index, value) in entries.enumerated() {
            guard let entry = value.objectValue, let seq = entry["seq"]?.intValue, let id = entry["id"]?.stringValue else {
                drop("invalid"); continue
            }
            let kind = entry["kind"]?.stringValue, role = entry["role"]?.stringValue
            let content = entry["content"]?.stringValue ?? ""
            var message = GrokBundleV1.Message(
                id: id, seq: seq, timestamp: entry["timestampMs"]?.intValue.map(GrokNaming.iso), replyTo: entry["replyTo"]?.stringValue,
                attachments: [], hidden: false, channel: "chat", to: nil, role: "", author: nil, text: "")
            if kind == "message", role == "user", !Self.present(entry["fromAgent"]) {
                message.role = "user"; message.text = redact(content)
            } else if kind == "message", role == "user" {
                let sender = entry["fromAgent"]?.objectValue ?? [:]
                message.role = "assistant"; message.channel = "agent"; message.text = redact(content)
                message.author = redact(agentName(sender)); message.to = redact(botName)
            } else if kind == "message", role == "assistant", Self.present(entry["toAgent"]) {
                let target = entry["toAgent"]?.objectValue ?? [:]
                message.role = "assistant"; message.channel = "agent"; message.author = redact(botName)
                message.text = redact(content); message.to = redact(agentName(target))
            } else if kind == "send-message" {
                let card = entry["message"]?.objectValue ?? [:]
                guard let text = GrokCardText.text(card) else {
                    drop("send-message/\(card["type"]?.stringValue ?? "unknown")", cards: true); continue
                }
                message.role = "assistant"; message.text = redact(text); message.attachments = GrokCardText.attachments(card)
                if let author = entry["author"]?.objectValue, !author.isEmpty {
                    let known = author["id"]?.stringValue.flatMap { names[$0] }
                    message.author = (known ?? author["name"]?.stringValue).map { redact($0) }
                } else {
                    message.author = botName
                }
            } else if kind == "notice" {
                message.role = "system"; message.text = redact(entry["text"]?.stringValue ?? "")
            } else if kind == "event" {
                let event = entry["event"]?.objectValue ?? [:]
                guard event["type"]?.stringValue == "name-changed",
                      let from = event["from"]?.stringValue, let to = event["to"]?.stringValue else {
                    drop("event/\(event["type"]?.stringValue ?? "unknown")", event: true); continue
                }
                let renamed = GrokBundleV1.Event(id: id, seq: seq, timestampMs: entry["timestampMs"] ?? .null,
                                                 from: redact(from), to: redact(to))
                events.append((index, renamed))
                continue
            } else {
                // Tool calls, reasoning and injected context are internal; never exported.
                drop(kind ?? "unknown"); continue
            }
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.attachments.isEmpty {
                drop("\(kind ?? "unknown")/empty"); continue
            }
            message.hidden = GrokRedactor.hasHiddenMarker(message.text)
            messages.append((index, message))
        }
        // A stable sort by seq, as Python's `list.sort`.
        return (messages.sorted { ($0.1.seq, $0.0) < ($1.1.seq, $1.0) }.map(\.1),
                events.sorted { ($0.1.seq, $0.0) < ($1.1.seq, $1.0) }.map(\.1))
    }

    /// `names.get(agent.id, agent.name or "Agent")`.
    private func agentName(_ agent: [String: JSONValue]) -> String {
        if let id = agent["id"]?.stringValue, let known = names[id] { return known }
        if let name = agent["name"]?.stringValue, !name.isEmpty { return name }
        return "Agent"
    }

    /// A key test, where an explicit `null` counts as absent.
    private static func present(_ value: JSONValue?) -> Bool { value.map { !$0.isNull } ?? false }
}

/// Visible text and attachment references for a bot's send-message card (port of `card_text` and `attachment_ref`).
enum GrokCardText {
    /// The text a user saw, or nil for an internal card (secret requests, connectors, forms, approvals).
    static func text(_ message: [String: JSONValue]) -> String? {
        let string = { (value: JSONValue?) in value?.stringValue ?? "" }
        switch message["type"]?.stringValue {
        case "text":
            return string(message["content"])
        case "widget":
            let widget = message["widget"]?.objectValue ?? [:]
            let prompt = string(widget["prompt"]).isEmpty ? string(message["content"]) : string(widget["prompt"])
            let options = (widget["options"]?.arrayValue ?? []).map { option -> String in
                let label = string(option["label"])
                return "• " + (label.isEmpty ? string(option["value"]) : label)
            }
            return ([prompt] + options).filter { !$0.isEmpty }.joined(separator: "\n")
        case "email-draft":
            let draft = message["draft"]?.objectValue ?? [:]
            return "Email draft — \(string(draft["subject"]))\n\n\(string(draft["body"]))"
        case "attachment":
            let base = basename(string(message["file_name"]))
            let alt = string(message["alt"])
            return "Attachment: " + (!base.isEmpty ? base : !alt.isEmpty ? alt : "file")
        default:
            return nil
        }
    }

    /// `attachments/<safe name>`, never available (attachment bytes are out of scope); the URL is never kept.
    static func attachments(_ message: [String: JSONValue]) -> [GrokBundleV1.Attachment] {
        guard message["type"]?.stringValue == "attachment", let name = message["file_name"]?.stringValue, !name.isEmpty else { return [] }
        var safe = "", inRun = false
        for scalar in basename(name).unicodeScalars {
            let allowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            if allowed { safe.unicodeScalars.append(scalar); inRun = false } else if !inRun { safe += "_"; inRun = true }
        }
        while safe.hasPrefix(".") { safe.removeFirst() }
        return [.init(file: "attachments/" + (safe.isEmpty ? "file" : safe), available: false)]
    }

    /// `os.path.basename`: the text after the last `/`.
    static func basename(_ path: String) -> String {
        path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
    }
}
