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
/// (`preview`, `label`, `message`), never from `args`; each is redacted and cut to one short line.
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
        return ToolEvent(phase: phase, name: name, preview: preview, callID: (json["tool_call_id"] ?? json["toolCallId"]) as? String)
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
        return ToolEvent(phase: phase, name: name, preview: phase == .started ? ToolEvent.preview(label, key: apiKey) : nil, callID: json["toolCallId"] as? String)
    }
}
