import Foundation

/// P52: the shape of an answer (or a bot's request) SwarmHub could not read, for the log, the chat and the bot: top-level
/// keys and their types and the byte size. Never a value; a key that is not a plain word (letters and `_`, at most 40,
/// so never an id, token or key) is only counted.
enum AppFailureShape {
    static let keyLimit = 12

    static func describe(_ data: Data) -> String {
        guard let value = try? JSONDecoder().decode(ComposioValue.self, from: data) else {
            var text = "not JSON, \(bytes(data.count))"
            if let extra = extraAfterObject(data), extra > 0 { text += ", one JSON object followed by \(bytes(extra)) more" }
            return text
        }
        return describe(value) + ", " + bytes(data.count)
    }

    static func describe(_ value: ComposioValue) -> String {
        guard case .object(let fields) = value else { return type(value) }
        let plain = fields.keys.filter(isPlainWord).sorted()
        var parts = plain.prefix(keyLimit).map { "\($0): \(type(fields[$0]!))" }
        let other = fields.count - min(plain.count, keyLimit)
        if other > 0 { parts.append("\(other) other key\(other == 1 ? "" : "s")") }
        return "object {" + parts.joined(separator: ", ") + "}"
    }

    static func type(_ value: ComposioValue) -> String {
        switch value {
        case .object: "object"
        case .array(let items): "array(\(items.count))"
        case .string: "string"
        case .number: "number"
        case .bool: "bool"
        case .null: "null"
        }
    }

    /// Bytes after the first complete top-level object (whitespace not counted); nil when the text does not start with one.
    static func extraAfterObject(_ data: Data) -> Int? {
        let bytes = Array(data)
        guard let start = bytes.firstIndex(where: { !isSpace($0) }), bytes[start] == UInt8(ascii: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return bytes[(index + 1)...].filter { !isSpace($0) }.count }
            default: break
            }
        }
        return nil
    }

    private static func bytes(_ count: Int) -> String { count == 1 ? "1 byte" : "\(count) bytes" }
    private static func isSpace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
    private static func isPlainWord(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 40 && key.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.letters.contains($0)) || $0 == "_" }
    }
}

/// P52: a bot's app request SwarmHub could not read. It goes back to the bot (with the shape, never the text) so it can
/// send it again; the turn goes on.
struct AppRequestError: LocalizedError {
    let reason: String
    var errorDescription: String? { "SwarmHub could not read the app request: \(reason). Send one JSON object exactly in the format shown." }
}
