import Foundation

/// P48: what Composio said on a non-2xx: `{"error":{"message","code","slug","status","request_id","suggested_fix",…}}`
/// (v3.1). Only these four fields are kept, each at most 300 characters with secrets and the project key removed; never a
/// header, the key or the request body.
struct ComposioFailure: Sendable, Equatable {
    static let fieldLimit = 300
    let status: Int; let message: String; let slug: String?; let suggestedFix: String?; let requestID: String?

    init?(status: Int, body: Data, key: String) {
        guard body.count <= 1_000_000, let value = try? JSONDecoder().decode(ComposioValue.self, from: body) else { return nil }
        let fields = value["error"].object != nil ? value["error"] : value
        let clean = { (raw: String?) -> String? in
            guard let raw else { return nil }
            let text = ToolEvent.redacted(raw.split(whereSeparator: \.isNewline).joined(separator: " "), key: key)
            return text.isEmpty ? nil : String(text.prefix(Self.fieldLimit))
        }
        guard let message = clean(fields["message"].string) else { return nil }
        self.status = status; self.message = message
        slug = clean(fields["slug"].string); suggestedFix = clean(fields["suggested_fix"].string); requestID = clean(fields["request_id"].string)
    }

    /// The chat's and the bot's text: "Composio: <message> (<slug>)" and the suggested fix when there is one.
    var line: String {
        var text = "Composio: \(message)" + (slug.map { " (\($0))" } ?? "")
        if let suggestedFix { text += " " + suggestedFix }
        switch status {
        case 401: text += " Update the key in Settings → Connected apps."
        case 403: text += " Check the Composio project's permissions."
        default: break
        }
        return text
    }
    /// The developer log's line: the same text with the HTTP status and Composio's request id.
    var logLine: String { "HTTP \(status): \(line)" + (requestID.map { " [request \($0)]" } ?? "") }
}
