import Foundation

/// Shared with the desktop adapter. Keep text below Hermes' normalization limit.
public enum HermesContent {
    public static let maxTextPartScalars = 60_000
    public static let maxRequestBodyBytes = 9_500_000

    public static func parts(text: String, images: [String] = [], limit: Int = maxTextPartScalars) -> Any {
        let pieces = splitText(text, limit: limit)
        if images.isEmpty && pieces.count <= 1 { return text }
        let textParts: [[String: Any]] = pieces.filter { !$0.isEmpty }.map { ["type": "text", "text": $0] }
        return textParts + images.map { ["type": "image_url", "image_url": ["url": $0]] }
    }

    public static func splitText(_ text: String, limit: Int = maxTextPartScalars) -> [String] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit, limit > 0 else { return [text] }
        var pieces: [String] = []; var start = 0
        while scalars.count - start > limit {
            let window = (start + 1)...min(start + limit, scalars.count - 1)
            let cut = window.reversed().first { scalars[$0] == "\n" } ?? window.reversed().first { scalars[$0] == " " }
            if let cut { pieces.append(string(scalars[start..<cut])); start = cut + 1 }
            else { pieces.append(string(scalars[start..<(start + limit)])); start += limit }
        }
        pieces.append(string(scalars[start...])); return pieces
    }

    public static func body(_ object: [String: Any], limit: Int = maxRequestBodyBytes) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= limit else { throw CoreError.requestTooLarge }
        return data
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView(); view.append(contentsOf: scalars); return String(view)
    }
}
