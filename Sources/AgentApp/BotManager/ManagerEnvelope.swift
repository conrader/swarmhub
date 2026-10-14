import Foundation

/// P26: OpenClaw has no system-prompt parameter, so on a management turn the manager text rides inside that turn's
/// user message as one marked block before Konrad's text. The chat bubble keeps his text only; history loaded from the
/// Gateway drops a leading block the same way, so it never shows in the transcript.
enum ManagerEnvelope {
    static let open = "<swarmhub-manager v=\"1\">", close = "</swarmhub-manager>"

    /// `<swarmhub-manager v="1">\n<text>\n</swarmhub-manager>\n\n<his text>`.
    static func wrap(_ managementText: String, around text: String) -> String {
        "\(open)\n\(managementText.trimmingCharacters(in: .whitespacesAndNewlines))\n\(close)\n\n\(text)"
    }

    /// The text without a leading marked block (leading whitespace allowed); anything else is returned unchanged.
    static func strip(_ text: String) -> String {
        let body = text.drop { $0.isWhitespace }
        guard body.hasPrefix(open), let end = body.range(of: close) else { return text }
        let rest = body[end.upperBound...]
        return String(rest.drop { $0 == "\n" || $0 == "\r" })
    }
}
