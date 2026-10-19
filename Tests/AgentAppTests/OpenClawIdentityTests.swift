import CryptoKit
import Foundation
import Testing
@testable import AgentApp

// P12 Part A: the Ed25519 identity. The vector uses a throwaway seed (computed with Node `crypto` for the brief and
// cross-checked there); the two Node signatures are VERIFIED with CryptoKit, never compared byte for byte.

private let vectorSeed = Data((1...32).map(UInt8.init))
private let vectorFields = DeviceAuthPayload.Fields(
    deviceId: "65b60673d6ed884bf01c2c222d82ada0740f29ac3355d6a925c81f17f47a27b8", clientId: "gateway-client", clientMode: "ui", role: "operator",
    scopes: ["operator.read", "operator.write", "operator.approvals"], signedAtMs: 1_737_264_000_000, token: "test-shared-token",
    nonce: "nonce-0123456789abcdef", platform: "macOS", deviceFamily: "Mac")
private let expectedV3 = "v3|65b60673d6ed884bf01c2c222d82ada0740f29ac3355d6a925c81f17f47a27b8|gateway-client|ui|operator|operator.read,operator.write,operator.approvals|1737264000000|test-shared-token|nonce-0123456789abcdef|macos|mac"
private let expectedV2 = "v2|65b60673d6ed884bf01c2c222d82ada0740f29ac3355d6a925c81f17f47a27b8|gateway-client|ui|operator|operator.read,operator.write,operator.approvals|1737264000000|test-shared-token|nonce-0123456789abcdef"
private let nodeV3Signature = "yhUHUTFQgMMbRXTw3AKIPpumngt9LOTux_vYAGxN-0J0F4yamWf8qkGsjD-7q-WrxeldBK5CAteNDzRGbds1BQ"
private let nodeV2Signature = "9cCfRKUG1ts7z_aNshv0je9U0lyrV-nfYcqzIKWxZhnXiHUMLI4w86f9UBJCouSP3zzxBTS0V6azgp67uOhTBA"

@Test func theKnownAnswerVectorMatches() throws {
    let identity = try GatewayIdentity(seed: vectorSeed)
    #expect(identity.publicKey == "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ")
    #expect(Base64URL.decode(identity.publicKey)?.map { String(format: "%02x", $0) }.joined() == "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664")
    #expect(identity.deviceId == vectorFields.deviceId)
    #expect(DeviceAuthPayload.v3(vectorFields) == expectedV3)
    #expect(DeviceAuthPayload.v2(vectorFields) == expectedV2)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(Base64URL.decode(identity.publicKey)))
    let decodedV3Signature = try #require(Base64URL.decode(nodeV3Signature))
    #expect(publicKey.isValidSignature(decodedV3Signature, for: Data(expectedV3.utf8)), "Node's v3 signature verifies")
    let decodedV2Signature = try #require(Base64URL.decode(nodeV2Signature))
    #expect(publicKey.isValidSignature(decodedV2Signature, for: Data(expectedV2.utf8)), "Node's v2 signature verifies")
    #expect(!publicKey.isValidSignature(decodedV3Signature, for: Data(expectedV2.utf8)))
    let ours = try identity.sign(expectedV3)
    let decodedOurs = try #require(Base64URL.decode(ours))
    #expect(publicKey.isValidSignature(decodedOurs, for: Data(expectedV3.utf8)), "our own signature verifies")
    #expect(!ours.contains("=") && !ours.contains("+") && !ours.contains("/"), "base64url without padding")
}

@Test func metadataIsTrimmedAndASCIILowercased() {
    #expect(DeviceAuthPayload.normalize("  macOS ") == "macos")
    #expect(DeviceAuthPayload.normalize("ÉCOLE Mac") == "École mac", "only A–Z change")
    #expect(DeviceAuthPayload.normalize(nil) == "")
    var fields = vectorFields; fields.platform = nil; fields.deviceFamily = nil; fields.token = ""
    #expect(DeviceAuthPayload.v3(fields).hasSuffix("|1737264000000||nonce-0123456789abcdef||"))
}

@Test func theIdentityIsStoredOnceAndReloadsTheSame() throws {
    let keys = InMemoryKeyStore()
    let first = try GatewayIdentity.loadOrCreate(gatewayID: "gw-1", store: keys)
    let again = try GatewayIdentity.loadOrCreate(gatewayID: "gw-1", store: keys)
    let other = try GatewayIdentity.loadOrCreate(gatewayID: "gw-2", store: keys)
    #expect(first.deviceId == again.deviceId && first.publicKey == again.publicKey)
    #expect(other.deviceId != first.deviceId, "one key per Gateway")
    #expect(Data(base64Encoded: keys.key(for: "openclaw.gw-1.device-key"))?.count == 32)
}

/// A store whose writes silently vanish (a Keychain that refused the item).
private final class RefusingKeyStore: HermesKeyStore, @unchecked Sendable {
    func key(for account: String) -> String { "" }
    func setKey(_ value: String, for account: String) {}
}

@Test func aKeychainThatDoesNotKeepTheKeyStopsWithAnError() {
    #expect(throws: GatewayIdentity.Failure.keychainWrite) { try GatewayIdentity.loadOrCreate(gatewayID: "gw-1", store: RefusingKeyStore()) }
    let damaged = InMemoryKeyStore(["openclaw.gw-1.device-key": "not base64!"])
    #expect(throws: GatewayIdentity.Failure.unreadableKey) { try GatewayIdentity.loadOrCreate(gatewayID: "gw-1", store: damaged) }
}

@Test func theKeyVaultVerifiesItsWrite() {
    final class Backend: KeychainBackend, @unchecked Sendable {
        var keeps: Bool; var stored: [String: String] = [:]
        init(keeps: Bool) { self.keeps = keeps }
        func read(service: String, account: String) -> (status: OSStatus, value: String?) { stored[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) }
        func add(_ value: String, service: String, account: String) -> OSStatus { if keeps { stored[account] = value; return errSecSuccess }; return errSecSuccess }
        func delete(service: String, account: String) -> OSStatus { stored[account] = nil; return errSecSuccess }
        func exists(service: String, account: String) -> Bool { stored[account] != nil }
        func allAccounts(service: String) -> [String] { Array(stored.keys) }
    }
    let good = KeyVault(backend: Backend(keeps: true), defaults: isolatedDefaults(), copiesLegacy: false)
    #expect(good.setVerified("abc", account: "openclaw.x.device-key") && good.get(account: "openclaw.x.device-key") == "abc")
    let liar = KeyVault(backend: Backend(keeps: false), defaults: isolatedDefaults(), copiesLegacy: false)
    #expect(!liar.setVerified("abc", account: "openclaw.x.device-key"), "add said OK but nothing reads back")
    #expect(liar.get(account: "openclaw.x.device-key").isEmpty, "never a memory-only key")
}

@Test func thePrivateKeyAppearsInNoDescription() throws {
    let keys = InMemoryKeyStore()
    let identity = try GatewayIdentity.loadOrCreate(gatewayID: "gw-1", store: keys)
    let seed = keys.key(for: "openclaw.gw-1.device-key")
    let seedHex = try #require(Data(base64Encoded: seed)).map { String(format: "%02x", $0) }.joined()
    for text in [String(reflecting: identity), String(describing: identity), "\(identity)", Mirror(reflecting: identity).children.map { "\($0.value)" }.joined()] {
        #expect(!text.contains(seed) && !text.contains(seedHex) && text.contains(identity.deviceId))
    }
}
