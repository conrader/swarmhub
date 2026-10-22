import Foundation
import SwarmHubCore

/// Shared encoding keeps desktop and iOS below Hermes' per-part and body limits.
extension HermesBackend {
    static let maxTextPartScalars = HermesContent.maxTextPartScalars
    static let maxRequestBodyBytes = HermesContent.maxRequestBodyBytes
    static let requestTooLargeMessage = CoreError.requestTooLarge.localizedDescription

    static func contentParts(text: String, images: [String], limit: Int = maxTextPartScalars) -> Any {
        HermesContent.parts(text: text, images: images, limit: limit)
    }
    static func splitText(_ text: String, limit: Int = maxTextPartScalars) -> [String] {
        HermesContent.splitText(text, limit: limit)
    }
    static func requestBody(_ object: [String: Any], limit: Int = maxRequestBodyBytes) throws -> Data {
        do { return try HermesContent.body(object, limit: limit) }
        catch CoreError.requestTooLarge { throw BackendError.unavailable(requestTooLargeMessage) }
    }
}

/// P27 D9: Hermes tool events as `ToolEvent`s. Previews come only from the display fields Hermes builds for this purpose
/// (`preview`, `label`, `message`), never from `args`; each is redacted and cut to one short line. P34: `args.command`
/// is retained for bot-msg and staged updater calls. Results are retained up to 1 MB for every tool.
extension HermesBackend {
    /// `tool.started|progress|completed|failed` on the native session stream (`tool_name` or `tool`, `preview`,
    /// `tool_call_id`/`toolCallId`; a completion with `error`/`is_error` true counts as failed).
    func nativeTool(_ event: String, _ json: [String: Any]) -> ToolEvent {
        let name = (json["tool_name"] ?? json["tool"]) as? String ?? ""
        let failed = event == "tool.failed" || (json["error"] as? Bool) == true || (json["is_error"] as? Bool) == true
        let phase: ToolEvent.Phase = switch event {
        case "tool.started": .started
        case "tool.progress": .progress
        default: failed ? .failed : .completed
        }
        let preview = phase == .progress ? nil : ToolEvent.preview(json["preview"] as? String, key: apiKey)
        return ToolEvent(phase: phase, name: name, preview: preview, callID: (json["tool_call_id"] ?? json["toolCallId"]) as? String,
                         command: phase == .started ? Self.peerEnableCommand(json["args"] ?? json["arguments"]) ?? Self.updaterStatusCommand(json["args"] ?? json["arguments"]) ?? Self.webhookPanelCommand(json["args"] ?? json["arguments"]) ?? Self.botMessageCommand(json["args"] ?? json["arguments"]) ?? Self.botMessageLine(json["preview"], key: apiKey) : nil,
                         result: phase == .completed || phase == .failed ? Self.toolResult(json) : nil)
    }

    /// The `command` of a step's args (an object, or its JSON text) when it runs bot-msg.
    static func botMessageCommand(_ args: Any?) -> String? {
        var object = args as? [String: Any]
        if object == nil, let text = args as? String, let data = text.data(using: .utf8) { object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        guard let command = (object?["command"] ?? object?["cmd"]) as? String, BotMessageCall.mentionsCall(command) else { return nil }
        return command
    }

    /// Keep status and bounded staging scripts for exact call binding. Staging carries IDs/hashes, never secrets.
    static func updaterStatusCommand(_ args: Any?) -> String? {
        var object = args as? [String: Any]
        if object == nil, let text = args as? String, let data = text.data(using: .utf8) { object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        guard let command = (object?["command"] ?? object?["cmd"]) as? String, command.utf8.count <= 32_768,
              command == StagedInstall.statusCommand || command.hasPrefix("python3 -I -B <<'SWARMHUB_STAGE'\n") ||
              command.range(of: "\\A" + NSRegularExpression.escapedPattern(for: StagedInstall.updater) +
                  #" --max-wait 0 apply --version [1-9][0-9]{0,18} && "# +
                  NSRegularExpression.escapedPattern(for: StagedInstall.receiverCommand) + #"\z"#, options: .regularExpression) != nil else { return nil }
        return command
    }

    /// The Webhooks section's one panel call (names and a key digest only, never a key), kept for exact call binding.
    static func webhookPanelCommand(_ args: Any?) -> String? {
        var object = args as? [String: Any]
        if object == nil, let text = args as? String { object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] }
        guard let command = (object?["command"] ?? object?["cmd"]) as? String, WebhookCommand.matches(command) else { return nil }
        return command
    }

    static func peerEnableCommand(_ args: Any?) -> String? {
        var object = args as? [String: Any]
        if object == nil, let text = args as? String { object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] }
        // A dev-mode call includes the skill's files and guard around the peer script (over 32 KB).
        guard let command = (object?["command"] ?? object?["cmd"]) as? String, command.utf8.count <= 1_048_576,
              command.hasPrefix("python3 - <<'SWARMHUB_PEER_ENABLE'\n") ||
              command.contains("\npython3 - <<'SWARMHUB_PEER_ENABLE'\n") else { return nil }
        return command
    }

    /// P41: a display line that runs bot-msg, uncut (its first line, secrets removed like a preview). A stream without
    /// args still gives the whole command this way; the 80-character preview would lose `--to`.
    static func botMessageLine(_ raw: Any?, key: String) -> String? {
        guard let raw = raw as? String, BotMessageCall.mentionsCall(raw) else { return nil }
        let first = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        // The cut-free twin of `ToolEvent.preview`: same redaction, no length limit.
        let redacted = ToolEvent.redacted(first, key: key)
        return BotMessageCall.call(in: redacted) != nil ? redacted : nil
    }

    /// An ended step's result text (`result`, `output` or `content`; an object is passed on as JSON).
    static func toolResult(_ json: [String: Any]) -> String? {
        for key in ["result", "output", "content"] {
            if let text = json[key] as? String { return String(text.prefix(1_048_576)) }
            if let object = json[key] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) { return String(decoding: data, as: UTF8.self) }
        }
        return nil
    }

    /// `hermes.tool.progress` on the legacy stream: `tool`/`label`/`toolCallId`/`status` (running, completed) on newer
    /// servers, `name`/`message` (one event per start) on older ones.
    func legacyTool(_ json: [String: Any]) -> ToolEvent {
        let name = (json["tool"] ?? json["name"]) as? String ?? "tool"
        let phase: ToolEvent.Phase = switch (json["status"] as? String)?.lowercased() {
        case "completed", "done", "finished": (json["error"] as? Bool) == true ? .failed : .completed
        case "failed", "error": .failed
        default: .started
        }
        let label = (json["label"] as? String).flatMap { $0 == name ? nil : $0 } ?? json["message"] as? String
        return ToolEvent(phase: phase, name: name, preview: phase == .started ? ToolEvent.preview(label, key: apiKey) : nil, callID: json["toolCallId"] as? String,
                         command: phase == .started ? Self.botMessageCommand(json["args"] ?? json["arguments"]) ?? Self.botMessageLine(label, key: apiKey) : nil)
    }
}
