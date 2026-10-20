import CryptoKit
import Foundation

/// Shared by Mac and iOS (P5d). P5a's integer-only JCS profile and disjoint read/decision signature domains.
public enum DeviceApprovalWire {
    public static let domain = "swarmhub/device-approval/2"
    public static let readDomain = "swarmhub/device-request/2"
    public static let context = "swarmhub-device-approval/2\n"
    public static let readContext = "swarmhub-device-request/2\n"
    public static let fields: Set<String> = ["version", "domain", "key_id", "origin", "runtime", "profile", "task",
                                      "fingerprint", "gate", "approved", "nonce", "issued", "expires"]
    public static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    public static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    public static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    /// HTTPS origin of a Hermes connection address (moved from the Mac's v1 client, unchanged).
    public static func baseOrigin(address: String) throws -> String {
        guard var parts = URLComponents(string: address), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/", "/v1", "/v1/"].contains(parts.path) else { throw ManagedControlError.unavailable }
        parts.path = ""
        parts.host = parts.host?.lowercased()
        guard let origin = parts.string else { throw ManagedControlError.unavailable }
        return origin
    }

    public static func validTask(_ value: String) -> Bool { value.range(of: "^task\\.[A-Za-z0-9_.-]{1,80}\\z", options: .regularExpression) != nil }
    public static func validProfile(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,80}\\z", options: .regularExpression) != nil }

    public static func origin(address: String) throws -> String {
        let result = try baseOrigin(address: address)
        guard matches(result, "https://[a-z0-9.-]+(?::[1-9][0-9]{0,4})?"),
              let parts = URLComponents(string: result), let host = parts.host,
              host.utf8.count <= 253, parts.port != 443, parts.port.map({ (1...65535).contains($0) }) ?? true,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  matches(String($0), "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
              }) else { throw ManagedControlError.unavailable }
        return result
    }

    public static func canonical(_ value: JSONValue, depth: Int = 0) throws -> Data {
        guard depth <= 32 else { throw ManagedControlError.invalidRecord }
        let text: String
        switch value {
        case .bool(let flag): text = flag ? "true" : "false"
        case .int(let number):
            guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(number) else { throw ManagedControlError.invalidRecord }
            text = String(number)
        case .string(let string): text = quote(string)
        case .array(let values):
            text = "[" + (try values.map { String(decoding: try canonical($0, depth: depth + 1), as: UTF8.self) }).joined(separator: ",") + "]"
        case .object(let fields):
            guard fields.keys.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) else { throw ManagedControlError.invalidRecord }
            text = "{" + (try fields.keys.sorted().map {
                quote($0) + ":" + String(decoding: try canonical(fields[$0]!, depth: depth + 1), as: UTF8.self)
            }).joined(separator: ",") + "}"
        default: throw ManagedControlError.invalidRecord
        }
        return Data(text.utf8)
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    public static func message(_ signed: [String: JSONValue], read: Bool = false) throws -> Data {
        Data((read ? readContext : context).utf8) + (try canonical(.object(signed)))
    }

    public static func envelope(_ signed: [String: JSONValue], identity: DeviceApprovalIdentity, read: Bool = false) throws -> Data {
        let signature = try identity.signature(for: message(signed, read: read))
        let result = try canonical(.object(["signed": .object(signed), "signature": .string(signature)]))
        guard result.count <= 16_384 else { throw ManagedControlError.invalidRecord }
        return result
    }

    public static func validateChallenge(_ body: [String: JSONValue], identity: DeviceApprovalIdentity, origin: String,
                                  profile: String, task: String, record: ManagedRecord) throws {
        guard Set(body.keys) == fields.subtracting(["approved"]), body["version"] == .int(2), body["domain"] == .string(domain),
              body["key_id"] == .string(identity.keyID), body["origin"] == .string(origin),
              body["profile"] == .string(profile), body["task"] == .string(task), record.id == task, record.decider == profile,
              record.awaiting, ["owner", "coordinator"].contains(record.gate), body["gate"] == .string(record.gate),
              let runtime = body["runtime"]?.stringValue, matches(runtime, "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"),
              let nonce = body["nonce"]?.stringValue, matches(nonce, "[a-f0-9]{64}"),
              let issued = body["issued"]?.intValue, let expires = body["expires"]?.intValue,
              issued >= 0, expires > issued, expires - issued <= 60,
              body["fingerprint"] == .string(try digest(canonical(.object(record.spec.fields)))) else {
            throw ManagedControlError.invalidRecord
        }
        _ = try canonical(.object(body))
    }
}
