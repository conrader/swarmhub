import CryptoKit
import Foundation

/// P12: this Mac's Ed25519 device identity for one Gateway (one key per Gateway, so two Gateways cannot correlate it).
/// The raw private key lives base64 in the Keychain (`openclaw.<gatewayID>.device-key`) and nowhere else; it appears
/// in no description, mirror or error text.
struct GatewayIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Lowercase hex SHA-256 of the raw 32-byte public key.
    let deviceId: String
    /// The raw public key, base64url without padding.
    let publicKey: String
    private let seed: Data

    enum Failure: LocalizedError, Equatable {
        case keychainWrite, unreadableKey
        var errorDescription: String? {
            switch self {
            case .keychainWrite: "The Keychain did not keep this Mac's OpenClaw device key, so nothing was sent."
            case .unreadableKey: "This Mac's OpenClaw device key in the Keychain is damaged. Forget the Gateway and add it again."
            }
        }
    }

    init(seed: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.seed = seed
        let raw = key.publicKey.rawRepresentation
        publicKey = Base64URL.encode(raw)
        deviceId = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    static func account(gatewayID: String) -> String { "openclaw.\(gatewayID).device-key" }

    /// The stored key, or a new one written and read back first; a failed write stops with an error (never a
    /// memory-only key that would pair a device nobody can use again).
    static func loadOrCreate(gatewayID: String, store: any HermesKeyStore) throws -> GatewayIdentity {
        let account = account(gatewayID: gatewayID)
        let stored = store.key(for: account)
        if !stored.isEmpty {
            guard let seed = Data(base64Encoded: stored), seed.count == 32, let identity = try? GatewayIdentity(seed: seed) else { throw Failure.unreadableKey }
            return identity
        }
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        guard store.storeVerified(seed.base64EncodedString(), for: account) else { throw Failure.keychainWrite }
        return try GatewayIdentity(seed: seed)
    }

    /// base64url (no padding) Ed25519 signature of the UTF-8 payload.
    func sign(_ payload: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return Base64URL.encode(try key.signature(for: Data(payload.utf8)))
    }

    var description: String { "GatewayIdentity(deviceId: \(deviceId))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["deviceId": deviceId, "publicKey": publicKey]) }
}

/// The signed connect string. The Gateway rebuilds it from the `connect` fields, so what is signed must equal what is sent.
enum DeviceAuthPayload {
    struct Fields: Sendable, Equatable {
        var deviceId: String; var clientId: String; var clientMode: String; var role: String; var scopes: [String]
        var signedAtMs: Int; var token: String; var nonce: String; var platform: String?; var deviceFamily: String?
    }

    /// `v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily`.
    static func v3(_ f: Fields) -> String { (v2Parts(f, prefix: "v3") + [normalize(f.platform), normalize(f.deviceFamily)]).joined(separator: "|") }
    /// `v2|…|nonce`: the Gateway still accepts it; used once after `DEVICE_AUTH_SIGNATURE_INVALID`.
    static func v2(_ f: Fields) -> String { v2Parts(f, prefix: "v2").joined(separator: "|") }

    private static func v2Parts(_ f: Fields, prefix: String) -> [String] {
        [prefix, f.deviceId, f.clientId, f.clientMode, f.role, f.scopes.joined(separator: ","), String(f.signedAtMs), f.token, f.nonce]
    }

    /// Trimmed and ASCII-lowercased (only A–Z change), empty when absent.
    static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        return String(String.UnicodeScalarView(value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }
}

enum Base64URL {
    static func encode(_ data: some DataProtocol) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
