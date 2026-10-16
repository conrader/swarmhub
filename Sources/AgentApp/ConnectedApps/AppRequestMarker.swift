import Foundation

/// P54: the shape of an app request's marker, `[[SWARMHUB_APP_REQUEST_<uuid>]]`. Each SwarmHub-run turn makes its own
/// (`ConnectedAppsChat`); a bot can copy an older one from its history, and that reply is still an app request, never plain
/// text. Only the start of the bot's own reply counts: a marker inside an app result (a user row SwarmHub wrote) or
/// later in a reply (quoted) is never read.
enum AppRequestMarker {
    static let prefix = "[[SWARMHUB_APP_REQUEST_"
    /// `prefix` + 36 UUID characters + `]]`.
    static let length = prefix.count + 36 + 2

    static func make() -> String { prefix + UUID().uuidString + "]]" }

    /// The marker a reply begins with (leading whitespace ignored), whatever turn it belongs to.
    static func leading(_ text: String) -> String? {
        let start = text.drop { $0.isWhitespace }
        guard start.count >= length else { return nil }
        let candidate = String(start.prefix(length))
        return fits(candidate) ? candidate : nil
    }

    /// While streaming: the reply so far (trimmed) may still become a marker, or already begins with one; such text is
    /// held back from the chat until the reply is complete.
    static func mayStart(_ trimmed: String) -> Bool {
        trimmed.count >= length ? leading(trimmed) != nil : fits(trimmed)
    }

    /// Whether `text` (at most `length` characters) matches the marker's shape as far as it goes.
    private static func fits(_ text: String) -> Bool {
        for (index, character) in text.enumerated() {
            switch index {
            case ..<prefix.count: if character != Array(prefix)[index] { return false }
            case ..<(prefix.count + 36): if !(character.isHexDigit || character == "-") { return false }
            case ..<length: if character != "]" { return false }
            default: return false
            }
        }
        return true
    }

}

