import Foundation

/// P12: a `Sendable` JSON tree (named apart from Grok's strict `JSONValue`) for the OpenClaw Gateway's frames, instead of `[String: Any]`. Integral numbers encode
/// without a fraction (timestamps, `minProtocol`); object keys encode sorted, so a frame's text is deterministic.
enum GatewayJSON: Sendable, Hashable, Codable {
    case null, bool(Bool), number(Double), string(String), array([GatewayJSON]), object([String: GatewayJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([GatewayJSON].self) { self = .array(value) }
        else if let value = try? container.decode([String: GatewayJSON].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value.") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Typed accessors (nil when the shape differs)

    subscript(key: String) -> GatewayJSON? { if case .object(let object) = self { object[key] } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var double: Double? { if case .number(let value) = self { value } else { nil } }
    var int: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }
    var array: [GatewayJSON]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: GatewayJSON]? { if case .object(let value) = self { value } else { nil } }
    var isNull: Bool { self == .null }
    /// The strings of an array, skipping anything else.
    var strings: [String] { array?.compactMap(\.string) ?? [] }

    // MARK: Text

    static func parse(_ text: String) -> GatewayJSON? { try? JSONDecoder().decode(GatewayJSON.self, from: Data(text.utf8)) }

    var jsonText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

extension GatewayJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: GatewayJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, GatewayJSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    static func int(_ value: Int) -> GatewayJSON { .number(Double(value)) }
}
