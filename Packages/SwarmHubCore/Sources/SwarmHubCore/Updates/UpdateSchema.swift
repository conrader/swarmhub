import Foundation
import CryptoKit

typealias UpdateObject = [String: JCS.Value]

/// Every accessor checks shape before use, including array elements and booleans vs integers.
struct UpdateShape {
    let stage: String

    func object(_ value: JCS.Value?) throws -> UpdateObject {
        guard case .object(let object)? = value else { throw invalid }
        return object
    }
    func array(_ value: JCS.Value?, nonempty: Bool = false) throws -> [JCS.Value] {
        guard case .array(let items)? = value, !nonempty || !items.isEmpty else { throw invalid }
        return items
    }
    func text(_ value: JCS.Value?, pattern: String? = nil) throws -> String {
        guard case .string(let text)? = value else { throw invalid }
        if let pattern { try requireUpdate(matches(text, pattern), stage) }
        return text
    }
    func number(_ value: JCS.Value?, low: Int64 = 0, high: Int64 = JCS.maxInteger) throws -> Int64 {
        guard case .integer(let number)? = value, number >= low, number <= high else { throw invalid }
        return number
    }
    func boolean(_ value: JCS.Value?) throws -> Bool {
        guard case .bool(let flag)? = value else { throw invalid }
        return flag
    }
    func time(_ value: JCS.Value?) throws -> String {
        let text = try text(value)
        try requireUpdate(validUpdateTime(text), stage)
        return text
    }
    func choice(_ value: JCS.Value?, _ allowed: Set<String>) throws -> String {
        let text = try text(value)
        try requireUpdate(allowed.contains(text), stage)
        return text
    }
    func stringSet(_ value: JCS.Value?, _ allowed: Set<String>) throws -> [String] {
        let strings = try array(value, nonempty: true).map { try choice($0, allowed) }
        try requireUpdate(Set(strings).count == strings.count, stage)
        return strings
    }
    func requires(_ value: JCS.Value?) throws -> [String: String] {
        let fields = try object(value)
        var result: [String: String] = [:]
        for (axis, value) in fields {
            let constraint = try text(value)
            try requireUpdate(matches(axis, "[a-z_]{1,32}") && validConstraint(constraint), stage)
            result[axis] = constraint
        }
        return result
    }
    var invalid: UpdateRejection { UpdateRejection(stage: stage, reason: "schema_invalid") }
}

let updateKeyID = "[A-Za-z0-9._-]{1,64}"
let updateName = "[a-z0-9][a-z0-9._-]{0,63}"
let updateVersion = "(0|[1-9][0-9]{0,8})(\\.(0|[1-9][0-9]{0,8})){0,3}"
let updateAxes: [String: Set<String>] = ["box": ["updater", "hermes"],
    "mac": ["app", "ui_catalog", "config_schema"], "ios": ["app", "ui_catalog", "config_schema"]]

func matches(_ text: String, _ pattern: String) -> Bool {
    // \z is absolute end; $ would also admit a trailing newline.
    text.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
}

func validUpdateTime(_ text: String) -> Bool {
    guard matches(text, "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z") else { return false }
    let digits = text.split(whereSeparator: { "-T:Z".contains($0) }).compactMap { Int($0) }
    guard digits.count == 6 else { return false }
    let year = digits[0], month = digits[1], day = digits[2]
    guard year >= 1, (1...12).contains(month), digits[3] < 24, digits[4] < 60, digits[5] < 60 else {
        return false
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return day >= 1 && day <= days[month - 1]
}

func constraintClauses(_ text: String) -> [(String, String)]? {
    guard !text.isEmpty else { return nil }
    var result: [(String, String)] = []
    for part in text.split(separator: ",", omittingEmptySubsequences: false) {
        let clause = String(part)
        guard let op = [">=", "<", "=="].first(where: { clause.hasPrefix($0) }) else { return nil }
        let version = String(clause.dropFirst(op.count))
        guard matches(version, updateVersion) else { return nil }
        result.append((op, version))
    }
    return result
}

func validConstraint(_ text: String) -> Bool { constraintClauses(text) != nil }

func compareVersions(_ left: String, _ right: String) -> Int {
    let a = left.split(separator: ".").compactMap { Int($0) }
    let b = right.split(separator: ".").compactMap { Int($0) }
    for index in 0..<4 {
        let x = index < a.count ? a[index] : 0
        let y = index < b.count ? b[index] : 0
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}

func satisfies(_ requires: [String: String], _ consumer: UpdateConsumer) -> Bool {
    guard let axes = updateAxes[consumer.platform] else { return false }
    let known: Set<String> = ["updater", "hermes", "app", "ui_catalog", "config_schema"]
    for (axis, constraint) in requires {
        guard known.contains(axis), let clauses = constraintClauses(constraint) else { return false }
        if !axes.contains(axis) { continue }
        guard let have = consumer.versions[axis] else { return false }
        for (op, want) in clauses {
            let order = compareVersions(have, want)
            if (op == ">=" && order < 0) || (op == "<" && order >= 0) || (op == "==" && order != 0) {
                return false
            }
        }
    }
    return true
}

struct UpdateSignature { let keyID: String; let hex: String }
struct UpdateEnvelope {
    let signed: UpdateObject
    let signatures: [UpdateSignature]
}

func parseUpdate(_ data: Data, stage: String, limits: UpdateLimits) throws -> JCS.Value {
    try requireUpdate(data.count <= limits.maxSignedBytes, stage)
    do { return try JCS.parse(data) } catch { throw UpdateRejection(stage: stage, reason: "schema_invalid") }
}

func updateEnvelope(_ data: Data, stage: String, limits: UpdateLimits) throws -> UpdateEnvelope {
    let s = UpdateShape(stage: stage)
    let envelope = try s.object(parseUpdate(data, stage: stage, limits: limits))
    try requireUpdate(Set(envelope.keys) == ["signed", "signatures"], stage)
    let signed = try s.object(envelope["signed"])
    let signatures = try s.array(envelope["signatures"], nonempty: true)
    try requireUpdate(stage == "keys" || signatures.count == 1, stage)
    return UpdateEnvelope(signed: signed, signatures: try signatures.map {
        let entry = try s.object($0)
        try requireUpdate(Set(entry.keys) == ["key_id", "sig"], stage)
        return UpdateSignature(keyID: try s.text(entry["key_id"], pattern: updateKeyID),
                               hex: try s.text(entry["sig"], pattern: "[0-9a-f]{128}"))
    })
}

func updateDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func hexBytes(_ text: String) -> Data {
    // Used only after exact lowercase-hex shape validation.
    let bytes = Array(text.utf8)
    func digit(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
    return Data(stride(from: 0, to: bytes.count, by: 2).map { digit(bytes[$0]) * 16 + digit(bytes[$0 + 1]) })
}

func validUpdateSignature(_ signature: UpdateSignature, publicHex: String, signed: UpdateObject) -> Bool {
    let publicBytes = hexBytes(publicHex)
    let signatureBytes = Array(hexBytes(signature.hex))
    // Pin canonical S and y encodings independently of the platform's CryptoKit backend.
    let order: [UInt8] = [0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
        0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14] + [UInt8](repeating: 0, count: 15) + [0x10]
    func canonicalPoint(_ bytes: [UInt8]) -> Bool {
        var y = bytes
        y[31] &= 0x7f
        let prime: [UInt8] = [0xed] + [UInt8](repeating: 0xff, count: 30) + [0x7f]
        guard y.reversed().lexicographicallyPrecedes(prime.reversed()) else { return false }
        // x = 0 has only sign 0 (y = 1 or p-1).
        let identity: [UInt8] = [1] + [UInt8](repeating: 0, count: 31)
        var minusOne = prime
        minusOne[0] -= 1
        return bytes[31] < 128 || (y != identity && y != minusOne)
    }
    guard signatureBytes[32...].reversed().lexicographicallyPrecedes(order.reversed()),
          canonicalPoint(Array(publicBytes)), canonicalPoint(Array(signatureBytes[..<32])),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicBytes),
          let canonical = try? JCS.canonical(.object(signed)) else { return false }
    let message = Data("swarmhub-signature/1\n".utf8) + canonical
    return key.isValidSignature(Data(signatureBytes), for: message)
}
