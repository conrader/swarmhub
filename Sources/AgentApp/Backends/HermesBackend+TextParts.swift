import Foundation

/// P19: Hermes silently cuts every text part and every plain-string `content` at 65,536 code points
/// (`MAX_NORMALIZED_TEXT_LENGTH`) and joins text parts with `\n` (`_normalize_multimodal_content`,
/// `gateway/platforms/api_server.py`). Every text that goes out passes through `contentParts`, which keeps
/// short text a plain string and splits long text into ordered parts the server's join reproduces.
extension HermesBackend {
    /// Unicode scalars per text part; below the server's 65,536 so a part is never cut.
    static let maxTextPartScalars = 60_000
    /// Hermes refuses bodies over 10,000,000 bytes (`MAX_REQUEST_BYTES`) with a 413; stop well before.
    static let maxRequestBodyBytes = 9_500_000
    static let requestTooLargeMessage = "This conversation is too large for one request. Start a new chat or fork it."

    /// Text plus `image_url` parts (the Chat Completions shape both Hermes endpoints normalise). Short text
    /// without images stays a plain string; text over `maxTextPartScalars` becomes several text parts.
    static func contentParts(text: String, images: [String], limit: Int = maxTextPartScalars) -> Any {
        let pieces = splitText(text, limit: limit)
        if images.isEmpty && pieces.count <= 1 { return text }
        let textParts: [[String: Any]] = pieces.filter { !$0.isEmpty }.map { ["type": "text", "text": $0] }
        return textParts + images.map { ["type": "image_url", "image_url": ["url": $0]] }
    }

    /// Splits `text` into pieces of at most `limit` Unicode scalars so that joining them with `\n` gives
    /// the original back: each cut drops one line break, else one space; only a window with neither is
    /// hard-cut (then the server's join adds one `\n`). Text within the limit comes back as one piece.
    static func splitText(_ text: String, limit: Int = maxTextPartScalars) -> [String] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit, limit > 0 else { return [text] }
        var pieces: [String] = []; var start = 0
        while scalars.count - start > limit {
            // The separator may sit just past a full window: dropping it still leaves `limit` scalars.
            let window = (start + 1)...min(start + limit, scalars.count - 1)
            let cut = window.reversed().first { scalars[$0] == "\n" } ?? window.reversed().first { scalars[$0] == " " }
            if let cut {
                pieces.append(Self.string(scalars[start..<cut])); start = cut + 1
            } else {
                pieces.append(Self.string(scalars[start..<(start + limit)])); start += limit
            }
        }
        pieces.append(Self.string(scalars[start...]))
        return pieces
    }

    /// Serialises a request body and refuses it before sending when it would exceed `maxRequestBodyBytes`.
    static func requestBody(_ object: [String: Any], limit: Int = maxRequestBodyBytes) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= limit else { throw BackendError.unavailable(requestTooLargeMessage) }
        return data
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView(); view.append(contentsOf: scalars); return String(view)
    }
}
