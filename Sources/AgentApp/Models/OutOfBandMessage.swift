import Foundation

/// P44: Hermes's `run_steer` lands in the running turn as a user row wrapped in `[OUT-OF-BAND USER MESSAGE …]` …
/// `[/OUT-OF-BAND USER MESSAGE]` (any header text). Wherever box rows become messages the inner text is the user's own
/// message, marked `SteerKey.outOfBand` ("Sent while <bot> was working"). Only user rows are read: an assistant reply
/// quoting the wrapper (in a code block, say) is left alone.
enum OutOfBandMessage {
    private static let wrapper = try! NSRegularExpression(
        pattern: #"\A\s*\[OUT-OF-BAND USER MESSAGE[^\]]*\]\s*([\s\S]*?)\s*\[/OUT-OF-BAND USER MESSAGE\]\s*\z"#)

    /// The inner text of a wrapped row; nil when the text is not one whole wrapper.
    static func unwrap(_ text: String) -> String? {
        guard text.contains("[/OUT-OF-BAND USER MESSAGE]") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = wrapper.firstMatch(in: text, range: range), let inner = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[inner])
    }

    static func label(botName: String?) -> String {
        "Sent while \(botName.flatMap { $0.isEmpty ? nil : $0 } ?? "the bot") was working"
    }
}
