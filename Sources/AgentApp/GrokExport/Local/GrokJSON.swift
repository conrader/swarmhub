import Foundation

/// A parsed JSON value that keeps bool, integer and double apart (Grok Bot's cache and the bundle oracle both rely on
/// `isinstance(x, int)`, which `NSNumber` and `as? Int` blur). Objects ignore key order; a repeated key keeps the
/// last value, as Python's `json` does.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    /// Only an integer JSON token: never `1.0`, never `true`.
    var intValue: Int64? { if case .int(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var isNull: Bool { self == .null }

    /// Python truthiness, for the few places `map_entries` uses `x or default`.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .int(let value): value != 0
        case .double(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        }
    }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

enum GrokJSONError: Error, Equatable { case invalid, tooDeep }

/// A strict RFC 8259 parser over UTF-8 bytes. Integer tokens that fit `Int64` become `.int`; any fraction or exponent
/// makes a `.double`.
enum GrokJSON {
    static let maximumDepth = 256

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw GrokJSONError.invalid }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < GrokJSON.maximumDepth else { throw GrokJSONError.tooDeep }
            guard index < bytes.count else { throw GrokJSONError.invalid }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw GrokJSONError.invalid
            }
            index += expected.count
        }

        mutating func object(depth: Int) throws -> JSONValue {
            index += 1
            var result: [String: JSONValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw GrokJSONError.invalid }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw GrokJSONError.invalid }
                index += 1
                skipWhitespace()
                result[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw GrokJSONError.invalid }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                guard bytes[index] == UInt8(ascii: "}") else { throw GrokJSONError.invalid }
                index += 1
                return .object(result)
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            index += 1
            var result: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
            while true {
                skipWhitespace()
                result.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw GrokJSONError.invalid }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                guard bytes[index] == UInt8(ascii: "]") else { throw GrokJSONError.invalid }
                index += 1
                return .array(result)
            }
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(data: Data(out), encoding: .utf8) else { throw GrokJSONError.invalid }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw GrokJSONError.invalid }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"): out.append(contentsOf: try unicodeEscape())
                    default: throw GrokJSONError.invalid
                    }
                case 0x00..<0x20: throw GrokJSONError.invalid
                default: out.append(byte)
                }
            }
            throw GrokJSONError.invalid
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw GrokJSONError.invalid }
            index += 4
            return value
        }

        /// `\uXXXX`, pairing surrogates; a lone surrogate becomes U+FFFD (Python keeps it, but it cannot be valid UTF-8).
        mutating func unicodeEscape() throws -> [UInt8] {
            var scalar = try hex4()
            if (0xD800..<0xDC00).contains(scalar), index + 6 <= bytes.count,
               bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let low = try hex4()
                if (0xDC00..<0xE000).contains(low) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) } else { index = saved }
            }
            return Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8)
        }

        mutating func number() throws -> JSONValue {
            let start = index
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw GrokJSONError.invalid }
            if bytes[index] == 0x30 { index += 1 } else { while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 } }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw GrokJSONError.invalid }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw GrokJSONError.invalid }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            if isInteger, let value = Int64(token) { return .int(value) }
            guard let value = Double(token) else { throw GrokJSONError.invalid }
            return .double(value)
        }
    }
}
