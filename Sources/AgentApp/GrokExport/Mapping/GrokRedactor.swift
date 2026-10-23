import Foundation

/// Counting secret filter for Grok bundles: `SecretFilter` with the `[REDACTED]` marker, counted per category like the
/// `Redactor` in `scripts/export-grokbot.py`. Not thread-shared: one per bundle, like the script.
struct GrokRedactor {
    static let marker = "[REDACTED]"
    private static let hiddenMarker = try! NSRegularExpression(pattern: #"\[GROK_BOT_HIDDEN[A-Z_]*\]"#)

    private(set) var counts: [String: Int] = [:]
    var total: Int { counts.values.reduce(0, +) }

    mutating func callAsFunction(_ text: String) -> String { SecretFilter.redact(text, replacement: Self.marker, counts: &counts) }

    /// `\[GROK_BOT_HIDDEN[A-Z_]*\]`, tested on the redacted text.
    static func hasHiddenMarker(_ text: String) -> Bool {
        hiddenMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
