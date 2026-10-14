import Foundation

/// P12: what a user sees of an OpenClaw message: `text` blocks only, with the delivery directives stripped and an exact
/// `NO_REPLY` (intentional silence) shown as an empty reply. Also used for history, so both compare equal.
enum OpenClawText {
    private static let directive = try! NSRegularExpression(pattern: #"\[\[\s*(?:reply_to_current|reply_to\s*:[^\]]*|audio_as_voice)\s*\]\][ \t]?"#)

    /// The visible text of a message (`content` as a string or as blocks), nil when it has none.
    static func visible(_ message: GatewayJSON?) -> String? {
        guard let message else { return nil }
        if let text = message["content"]?.string { return clean(text) }
        guard let blocks = message["content"]?.array else { return message["text"]?.string.map(clean) }
        let texts = blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
        return clean(texts.joined(separator: "\n\n"))
    }

    /// Image blocks as `[Image: name]` lines (history rows), like Hermes's transcript.
    static func imageLines(_ message: GatewayJSON) -> [String] {
        (message["content"]?.array ?? []).filter { $0["type"]?.string == "image" }.map { block in
            "[Image: \(block["fileName"]?.string ?? block["mimeType"]?.string ?? "image")]"
        }
    }

    /// For history comparison (P12 item 11): complete directives removed and `NO_REPLY` empty, on both sides alike.
    static func comparable(_ text: String) -> String {
        let value = directive.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return ["NO_REPLY", "no_reply"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines)) ? "" : value
    }

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var value = directive.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // While streaming, hold back an unfinished directive at the end instead of flashing it.
        if let open = value.range(of: "[[", options: .backwards), !value[open.upperBound...].contains("]]") { value = String(value[..<open.lowerBound]) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["NO_REPLY", "no_reply"].contains(trimmed) { return "" }
        return value
    }
}

/// Maps one run's `chat` and `agent` events to `AgentEvent`s (pure; one per send). Before the ack the run is unknown,
/// so events are matched by session key and buffered by the caller; after it, only the primary run counts. A `message`
/// is the authoritative full snapshot; `replace:true` means `deltaText` is the whole new text; an append without a
/// baseline is skipped (the reference client's `mergeChatStreamMessage`). The highest `seq` per run wins; repeats are
/// ignored; terminal events of steer runs are ignored.
struct OpenClawRunMapper {
    let sessionKey: String
    private(set) var primaryRunId: String?
    private(set) var ignoredRuns: Set<String> = []
    private(set) var text = ""
    private(set) var isFinished = false
    private var hasBaseline = false
    private var rawText = ""
    private var lastSeq: [String: Int] = [:]

    init(sessionKey: String) { self.sessionKey = sessionKey }

    mutating func setPrimary(_ runId: String) { primaryRunId = runId; ignoredRuns.remove(runId) }
    /// A steer's own run (when it is not the primary run, which a steer can join).
    mutating func ignore(_ runId: String) { if runId != primaryRunId { ignoredRuns.insert(runId) } }
    /// Resume after a reconnect from the Gateway's in-flight text.
    mutating func resume(from inFlightText: String) { rawText = inFlightText; hasBaseline = true; text = OpenClawText.clean(inFlightText) }
    /// The reply came from `chat.history` after a reconnect.
    mutating func finishFromHistory() { isFinished = true }

    /// Whether an event belongs to this run (call once the primary run is known).
    func belongs(_ event: GatewayEvent) -> Bool {
        guard let runId = event.payload["runId"]?.string, runId == primaryRunId else { return false }
        if event.event == "chat" { return event.payload["sessionKey"]?.string.map { $0.lowercased() == sessionKey.lowercased() } ?? true }
        return event.event == "agent"
    }

    mutating func map(_ event: GatewayEvent) -> [AgentEvent] {
        guard !isFinished, belongs(event), let runId = event.payload["runId"]?.string else { return [] }
        if let seq = event.payload["seq"]?.int ?? event.seq {
            let key = "\(event.event)|\(runId)"
            if let last = lastSeq[key], seq <= last { return [] }
            lastSeq[key] = seq
        }
        return event.event == "agent" ? mapAgent(event.payload) : mapChat(event.payload)
    }

    private mutating func mapChat(_ payload: GatewayJSON) -> [AgentEvent] {
        switch payload["state"]?.string {
        case "delta":
            if let message = payload["message"], !message.isNull {
                return show(rawSnapshot: Self.rawText(message))
            }
            guard let delta = payload["deltaText"]?.string else { return [] }
            if payload["replace"]?.bool == true { return show(rawSnapshot: delta, replacing: true) }
            guard hasBaseline, !delta.isEmpty else { return [] }
            return show(rawSnapshot: rawText + delta)
        case "final":
            isFinished = true
            var events: [AgentEvent] = []
            if let message = payload["message"], !message.isNull, let final = OpenClawText.visible(message), final != text {
                text = final; events.append(.replace(final))
            }
            return events + [.completed]
        case "aborted":
            isFinished = true
            return [.completed]
        case "error":
            isFinished = true
            return [.failed(Self.errorText(payload))]
        case "status":
            if let phase = payload["phase"]?.string { return [.status(Self.phaseText(phase))] }
            if let retry = payload["retry"], let attempt = retry["attempt"]?.int, let total = retry["maxAttempts"]?.int {
                return [.status("Rate limited; retrying (\(attempt) of \(total))…")]
            }
            return []
        default: return []
        }
    }

    /// `stream: "tool"` (`data.phase`, `data.name`, optional `data.toolCallId`/`data.isError`) as P27 activity steps; the
    /// optional `data.args`/`data.meta` are never read, so OpenClaw steps carry no preview.
    private func mapAgent(_ payload: GatewayJSON) -> [AgentEvent] {
        guard payload["stream"]?.string == "tool", let name = payload["data"]?["name"]?.string, !name.isEmpty else { return [] }
        let callID = payload["data"]?["toolCallId"]?.string
        switch payload["data"]?["phase"]?.string ?? "start" {
        case "start": return [.tool(ToolEvent(phase: .started, name: name, callID: callID))]
        case "running", "update": return [.tool(ToolEvent(phase: .progress, name: name, callID: callID))]
        case "result", "end", "done", "error":
            let failed = payload["data"]?["phase"]?.string == "error" || payload["data"]?["isError"]?.bool == true
            return [.tool(ToolEvent(phase: failed ? .failed : .completed, name: name, callID: callID))]
        default: return []
        }
    }

    /// The visible text of a new raw snapshot: a `.token` when it extends what is shown, else `.replace`.
    private mutating func show(rawSnapshot: String, replacing: Bool = false) -> [AgentEvent] {
        rawText = rawSnapshot; hasBaseline = true
        let visible = OpenClawText.clean(rawSnapshot)
        defer { text = visible }
        if visible == text { return [] }
        if !replacing, visible.hasPrefix(text) { return [.token(String(visible.dropFirst(text.count)))] }
        return [.replace(visible)]
    }

    /// The raw text blocks of a snapshot (directives kept, so later appends line up).
    static func rawText(_ message: GatewayJSON) -> String {
        if let text = message["content"]?.string { return text }
        let blocks = message["content"]?.array ?? []
        return blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n\n")
    }

    static func errorText(_ payload: GatewayJSON) -> String {
        let kind: String? = switch payload["errorKind"]?.string {
        case "rate_limit": "The model provider is rate limiting this agent."
        case "timeout": "The model took too long to answer."
        case "context_length": "The conversation is too long for the model's context."
        case "refusal": "The model declined to answer."
        case "state_contention": "The session was busy with another change."
        default: nil
        }
        let message = payload["errorMessage"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (kind, message.isEmpty) {
        case (let kind?, true): return kind
        case (let kind?, false): return "\(kind) (\(message))"
        case (nil, false): return message
        case (nil, true): return "The OpenClaw run failed."
        }
    }

    static func phaseText(_ phase: String) -> String {
        switch phase {
        case "starting_model": "Starting the model…"
        case "preparing_context": "Preparing context…"
        case "memory_flushing": "Saving memory…"
        case "waiting_for_state": "Waiting for the session…"
        default: phase.replacingOccurrences(of: "_", with: " ").capitalized + "…"
        }
    }
}
