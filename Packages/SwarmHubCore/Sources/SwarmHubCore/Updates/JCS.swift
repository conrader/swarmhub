import Foundation

/// RFC 8785 restricted profile from SCHEMAS.md §2. No Foundation JSON number coercion.
public enum JCS {
    public indirect enum Value: Equatable, Sendable {
        case object([String: Value]), array([Value]), string(String), integer(Int64), bool(Bool)
    }

    public enum Invalid: Error { case json }
    public static let maxInteger: Int64 = 9_007_199_254_740_991

    public static func parse(_ data: Data) throws -> Value {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw Invalid.json }
        return value
    }

    public static func canonical(_ value: Value) throws -> Data {
        Data(try encode(value, depth: 0).utf8)
    }

    private static func encode(_ value: Value, depth: Int) throws -> String {
        guard depth <= 32 else { throw Invalid.json }
        switch value {
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value):
            guard value >= -maxInteger, value <= maxInteger else { throw Invalid.json }
            return String(value)
        case .string(let value): return quote(value)
        case .array(let values):
            return "[" + (try values.map { try encode($0, depth: depth + 1) }).joined(separator: ",") + "]"
        case .object(let values):
            guard values.keys.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) else { throw Invalid.json }
            return "{" + (try values.keys.sorted().map {
                // A key from this dictionary always has a value.
                try quote($0) + ":" + encode(values[$0]!, depth: depth + 1)
            }).joined(separator: ",") + "}"
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0...31: result += "\\u00" + String(format: "%02x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth <= 32 else { throw Invalid.json }
            whitespace()
            guard offset < bytes.count else { throw Invalid.json }
            switch bytes[offset] {
            case 123:
                offset += 1
                whitespace()
                var result: [String: Value] = [:]
                if consume(125) { return .object(result) }
                repeat {
                    whitespace()
                    let key = try string()
                    guard key.utf8.allSatisfy({ $0 < 128 }), result[key] == nil else { throw Invalid.json }
                    whitespace()
                    guard consume(58) else { throw Invalid.json }
                    result[key] = try value(depth: depth + 1)
                    whitespace()
                    if consume(125) { return .object(result) }
                    guard consume(44) else { throw Invalid.json }
                } while true
            case 91:
                offset += 1
                whitespace()
                var result: [Value] = []
                if consume(93) { return .array(result) }
                repeat {
                    result.append(try value(depth: depth + 1))
                    whitespace()
                    if consume(93) { return .array(result) }
                    guard consume(44) else { throw Invalid.json }
                } while true
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 45, 48...57: return try number()
            default: throw Invalid.json
            }
        }

        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { guard consume(byte) else { throw Invalid.json } }
        }

        mutating func number() throws -> Value {
            let start = offset
            _ = consume(45)
            guard offset < bytes.count else { throw Invalid.json }
            if !consume(48) {
                guard (49...57).contains(bytes[offset]) else { throw Invalid.json }
                repeat { offset += 1 } while offset < bytes.count && (48...57).contains(bytes[offset])
            }
            let text = String(decoding: bytes[start..<offset], as: UTF8.self)
            guard text != "-0", let value = Int64(text), value >= -JCS.maxInteger, value <= JCS.maxInteger else {
                throw Invalid.json
            }
            // Fractions, exponents and leading zeroes remain unread and fail the enclosing parser.
            return .integer(value)
        }

        mutating func hexQuad() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard offset < bytes.count else { throw Invalid.json }
                let byte = bytes[offset]
                offset += 1
                let digit: UInt32
                switch byte {
                case 48...57: digit = UInt32(byte - 48)
                case 65...70: digit = UInt32(byte - 55)
                case 97...102: digit = UInt32(byte - 87)
                default: throw Invalid.json
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func string() throws -> String {
            guard consume(34) else { throw Invalid.json }
            var output: [UInt8] = []
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 34 {
                    // Validate only: Foundation's decoder may drop a leading U+FEFF, which is a character here.
                    guard String(bytes: output, encoding: .utf8) != nil else { throw Invalid.json }
                    return String(decoding: output, as: UTF8.self)
                }
                guard byte >= 32 else { throw Invalid.json }
                if byte != 92 { output.append(byte); continue }
                guard offset < bytes.count else { throw Invalid.json }
                let escape = bytes[offset]
                offset += 1
                switch escape {
                case 34, 47, 92: output.append(escape)
                case 98: output.append(8)
                case 116: output.append(9)
                case 110: output.append(10)
                case 102: output.append(12)
                case 114: output.append(13)
                case 117:
                    var code = try hexQuad()
                    if (0xD800...0xDBFF).contains(code) {
                        guard consume(92), consume(117) else { throw Invalid.json }
                        let low = try hexQuad()
                        guard (0xDC00...0xDFFF).contains(low) else { throw Invalid.json }
                        code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw Invalid.json }
                    output.append(contentsOf: String(scalar).utf8)
                default: throw Invalid.json
                }
            }
            throw Invalid.json
        }
    }
}
