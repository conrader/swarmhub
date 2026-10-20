import Foundation

/// Strict response parser: unique ASCII keys, valid UTF-8, no BOM or lone surrogates.
/// Receipts may contain null and floating timestamps; signed objects use Wire.canonical.
public enum DeviceApprovalJSON {
    public static let maximumDepth = 33

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ManagedControlError.invalidRecord }
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
            guard depth < DeviceApprovalJSON.maximumDepth else { throw ManagedControlError.invalidRecord }
            guard index < bytes.count else { throw ManagedControlError.invalidRecord }
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
                throw ManagedControlError.invalidRecord
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
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ManagedControlError.invalidRecord }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ManagedControlError.invalidRecord }
                index += 1
                skipWhitespace()
                guard result[key] == nil, key.utf8.allSatisfy({ $0 < 128 }) else { throw ManagedControlError.invalidRecord }
                result[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw ManagedControlError.invalidRecord }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                guard bytes[index] == UInt8(ascii: "}") else { throw ManagedControlError.invalidRecord }
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
                guard index < bytes.count else { throw ManagedControlError.invalidRecord }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                guard bytes[index] == UInt8(ascii: "]") else { throw ManagedControlError.invalidRecord }
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
                    guard let text = String(data: Data(out), encoding: .utf8) else { throw ManagedControlError.invalidRecord }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw ManagedControlError.invalidRecord }
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
                    default: throw ManagedControlError.invalidRecord
                    }
                case 0x00..<0x20: throw ManagedControlError.invalidRecord
                default: out.append(byte)
                }
            }
            throw ManagedControlError.invalidRecord
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, bytes[index..<index + 4].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw ManagedControlError.invalidRecord }
            index += 4
            return value
        }

        /// Reject lone surrogates instead of repairing signed text.
        mutating func unicodeEscape() throws -> [UInt8] {
            var scalar = try hex4()
            if (0xD800..<0xDC00).contains(scalar), index + 6 <= bytes.count,
               bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let low = try hex4()
                if (0xDC00..<0xE000).contains(low) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) } else { index = saved }
            }
            guard let scalar = Unicode.Scalar(scalar) else { throw ManagedControlError.invalidRecord }
            return Array(String(scalar).utf8)
        }

        mutating func number() throws -> JSONValue {
            let start = index
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw ManagedControlError.invalidRecord }
            if bytes[index] == 0x30 { index += 1 } else { while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 } }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw ManagedControlError.invalidRecord }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw ManagedControlError.invalidRecord }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            guard token != "-0" else { throw ManagedControlError.invalidRecord }
            if isInteger, let value = Int64(token), (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value) { return .int(value) }
            guard !isInteger else { throw ManagedControlError.invalidRecord }
            guard let value = Double(token), value.isFinite else { throw ManagedControlError.invalidRecord }
            return .double(value)
        }
    }
}
