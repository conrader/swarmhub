import Foundation

/// Counting secret filter for Grok bundles (port of `Redactor` in `scripts/export-grokbot.py`). Same patterns and order
/// as `GrokTemplateParser.secretValuePatterns`, compiled once. `credential_assignment` is re-applied until stable
/// (at most 50 passes); Basic credentials only when strict base64 decodes to UTF-8 text containing `:`.
/// Not thread-shared: one per bundle, like the script.
struct GrokRedactor {
    static let marker = "[REDACTED]"
    static let categories = [
        "private_key", "bearer", "vendor_token", "github_pat", "jwt", "aws_key", "google_key", "slack_app_token",
        "slack_webhook", "url_credentials", "credential_assignment",
    ]
    private static let expressions: [NSRegularExpression] = GrokTemplateParser.secretValuePatterns.map {
        // The patterns are constants covered by tests; a failure here is a programming error.
        try! NSRegularExpression(pattern: $0)
    }
    private static let basic = try! NSRegularExpression(pattern: #"(?i)\bBasic\s+([A-Za-z0-9+/]{4,}={0,2})(?![A-Za-z0-9+/=])"#)
    private static let hiddenMarker = try! NSRegularExpression(pattern: #"\[GROK_BOT_HIDDEN[A-Z_]*\]"#)
    private static let template = NSRegularExpression.escapedTemplate(for: marker)

    private(set) var counts: [String: Int] = [:]
    var total: Int { counts.values.reduce(0, +) }

    mutating func callAsFunction(_ text: String) -> String {
        var text = redactBasic(text)
        for (category, expression) in zip(Self.categories, Self.expressions) {
            for _ in 0..<50 {
                let range = NSRange(text.startIndex..., in: text)
                let hits = expression.numberOfMatches(in: text, range: range)
                if hits > 0 {
                    text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: Self.template)
                    counts[category, default: 0] += hits
                }
                if hits == 0 || category != "credential_assignment" { break }
            }
        }
        return text
    }

    private mutating func redactBasic(_ text: String) -> String {
        var result = text
        for match in Self.basic.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let credential = Range(match.range(at: 1), in: result),
                  let decoded = Data(base64Encoded: String(result[credential])),
                  String(data: decoded, encoding: .utf8)?.contains(":") == true else { continue }
            result.replaceSubrange(whole, with: Self.marker)
            counts["basic_auth", default: 0] += 1
        }
        return result
    }

    /// `\[GROK_BOT_HIDDEN[A-Z_]*\]`, tested on the redacted text.
    static func hasHiddenMarker(_ text: String) -> Bool {
        hiddenMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
