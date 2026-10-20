import Foundation

/// P54: the shape of an app request's marker, `[[SWARMHUB_APP_REQUEST_<uuid>]]`. Each SwarmHub-run turn makes its own
/// (`ConnectedAppsChat`); a bot can copy an older one from its history, and that reply is still an app request, never plain
/// text. Only the start of the bot's own reply counts: a marker inside an app result (a user row SwarmHub wrote) or
/// later in a reply (quoted) is never read.
enum AppRequestMarker {
    static let prefix = "[[SWARMHUB_APP_REQUEST_"
    /// `prefix` + 36 UUID characters + `]]`.
    static let length = prefix.count + 36 + 2

    /// P54 item 5: the line under a turn that ended with an app request nothing ran.
    static let notRun = "This app request was not run"

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

    /// P54 item 2: one complete JSON object followed only by whitespace and stray `}` / `]` (`{…}}}`): the object, and
    /// how many characters were trimmed. Nil for anything else (an incomplete object, other text after it).
    static func trimmedObject(_ body: String) -> (json: String, trimmed: Int)? {
        let bytes = Array(body.utf8)
        guard bytes.first == UInt8(ascii: "{") else { return nil }
        var depth = 0, inString = false, escaped = false, end: Int?
        scan: for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { end = index; break scan }
            default: break
            }
        }
        guard let end else { return nil }
        let rest = bytes[(end + 1)...]
        let stray = rest.filter { $0 == UInt8(ascii: "}") || $0 == UInt8(ascii: "]") }.count
        guard stray > 0, rest.allSatisfy({ [9, 10, 13, 32, UInt8(ascii: "}"), UInt8(ascii: "]")].contains($0) }) else { return nil }
        return (String(decoding: bytes[...end], as: UTF8.self), stray)
    }
}

/// P54 item 3: an execute of a tool the bot never discovered in this turn. It goes back to the bot; the turn goes on.
struct AppUnknownToolError: LocalizedError {
    let tool: String
    var errorDescription: String? { "unknown tool \(tool); search first, then use a tool slug from the search result." }
}

/// P38 B: a tool SwarmHub never runs for a bot (`COMPOSIO_*`). It ends the turn with a line.
struct AppForbiddenToolError: LocalizedError {
    let tool: String
    var errorDescription: String? { "The bot requested \(tool), a tool SwarmHub never runs." }
}
