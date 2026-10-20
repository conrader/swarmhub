import CryptoKit
import Foundation
import Testing
@testable import SwarmHubCore

/// P5d: the device-signed client moved from the Mac app. These read the same TEST fixtures the Mac tests use;
/// signatures may be randomized, so stored signatures are verified, never byte-compared with fresh ones.
enum DeviceApprovalFixtures {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: UpdateVerifierTests.repository.appendingPathComponent("Tests/Fixtures/release-bundles/" + name))
    }
    static func hex(_ text: String) -> Data {
        var data = Data(), index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<end], radix: 16)!)
            index = end
        }
        return data
    }
    static func identity(_ number: Int = 0, keyID: String? = "TEST-device-1") throws -> DeviceApprovalIdentity {
        let keys = try #require(try DeviceApprovalJSON.parse(data("TEST-device-keys.json"))["keys"]?.arrayValue)
        return try DeviceApprovalIdentity(seed: hex(try #require(keys[number]["seed"]?.stringValue)), keyID: keyID)
    }
    static func defaults() -> UserDefaults {
        let suite = "p5d-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

final class MemoryApprovalKeyStore: DeviceApprovalKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var seeds: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { seeds[account] } }
    func insert(_ seed: Data, account: String) throws { lock.withLock { seeds[account] = seed } }
}

struct DeviceApprovalCoreTests {
    @Test func macFixtureBytesAndSignaturesVerifyThroughTheSharedWire() throws {
        let document = try DeviceApprovalJSON.parse(DeviceApprovalFixtures.data("TEST-mac-device-signatures.json"))
        #expect(document["schema"] == .string("swarmhub/mac-device-signatures/2"))
        let cases = try #require(document["cases"]?.arrayValue)
        #expect(cases.count == 38)
        for entry in cases {
            let canonical = try #require(entry["canonical"]?.stringValue)
            let signed = try #require(try DeviceApprovalJSON.parse(Data(canonical.utf8)).objectValue)
            #expect(try DeviceApprovalWire.canonical(.object(signed)) == Data(canonical.utf8))
            let message = try DeviceApprovalWire.message(signed)
            let stored = try #require(entry["message"]?.stringValue), publicKey = try #require(entry["public_key"]?.stringValue)
            let signature = try #require(entry["signature"]?.stringValue), envelopeText = try #require(entry["envelope"]?.stringValue)
            #expect(message == Data(stored.utf8))
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: DeviceApprovalFixtures.hex(publicKey))
            #expect(key.isValidSignature(DeviceApprovalFixtures.hex(signature), for: message))
            let envelope = try DeviceApprovalJSON.parse(Data(envelopeText.utf8))
            #expect(envelope["signed"] == .object(signed))
        }
    }

    @Test func identitySignsBothDomainsWithTheEnrolledKey() throws {
        let identity = try DeviceApprovalFixtures.identity()
        #expect(identity.publicKey == "5f5d136918c19c5cac8b2a8ac2fd847d0ca925d96d3e821e2c2646b5ecc0e7f9")
        let body: [String: JSONValue] = ["version": .int(2), "domain": .string(DeviceApprovalWire.readDomain), "verb": .string("receipt"),
                                         "key_id": .string(identity.keyID), "origin": .string("https://box.example.invalid"),
                                         "profile": .string("owner"), "task": .string("task." + String(repeating: "a", count: 32)), "issued": .int(1000)]
        let envelope = try DeviceApprovalJSON.parse(DeviceApprovalWire.envelope(body, identity: identity, read: true))
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: DeviceApprovalFixtures.hex(identity.publicKey))
        let signature = DeviceApprovalFixtures.hex(try #require(envelope["signature"]?.stringValue))
        #expect(key.isValidSignature(signature, for: try DeviceApprovalWire.message(body, read: true)))
        #expect(!key.isValidSignature(signature, for: try DeviceApprovalWire.message(body)))
        #expect(!String(reflecting: identity).contains("seed") && identity.customMirror.children.count == 2)
    }

    @Test func iosKeysUseTheirOwnPrefixAndPerBoxAccounts() throws {
        let keys = MemoryApprovalKeyStore()
        let ios = try DeviceApprovalIdentity.loadOrCreate(box: "https://box.example.invalid", store: keys, prefix: DeviceApprovalIdentity.iosKeyPrefix)
        let again = try DeviceApprovalIdentity.loadOrCreate(box: "https://box.example.invalid", store: keys, prefix: DeviceApprovalIdentity.iosKeyPrefix)
        let other = try DeviceApprovalIdentity.loadOrCreate(box: "https://other.example.invalid", store: keys, prefix: DeviceApprovalIdentity.iosKeyPrefix)
        #expect(ios.keyID.hasPrefix("ios-") && ios.keyID.count == 52 && DeviceApprovalWire.matches(ios.keyID, "[A-Za-z0-9._-]{1,64}"))
        #expect(ios.keyID == again.keyID && ios.publicKey == again.publicKey && ios.publicKey != other.publicKey)
        // The Mac default is unchanged, so existing Mac identities keep their key IDs.
        #expect(try DeviceApprovalIdentity(seed: Data(repeating: 7, count: 32)).keyID.hasPrefix("mac-"))
        #expect(DeviceApprovalKeychain.service == "com.swarmhub.device-approvals.v2")
        #expect(throws: DeviceApprovalIdentity.Failure.self) {
            try DeviceApprovalKeychain(refuses: { _ in true }).read(account: DeviceApprovalIdentity.account(box: "box"))
        }
    }

    @Test func requiredRoutingIsStickyAndAttemptsRoundTrip() throws {
        let settings = DeviceApprovalSettings(defaults: DeviceApprovalFixtures.defaults())
        let origin = "https://box.example.invalid", task = "task." + String(repeating: "a", count: 32)
        #expect(!settings.isRequired(origin))
        settings.confirmOperatorCutover(origin)
        #expect(settings.isRequired(origin) && !settings.isRequired("https://other.example.invalid"))
        let signed: [String: JSONValue] = ["approved": .bool(true), "nonce": .string(String(repeating: "1", count: 64))]
        try settings.remember(signed, origin: origin, task: task)
        #expect(try settings.attempt(origin: origin, task: task) == signed)
        try settings.clearRefusedAttempt(origin: origin, task: task)
        #expect(!settings.hasAttempt(origin: origin, task: task))
    }

    @Test(arguments: ["https://Box.Example.Invalid/v1/", "https://box.example.invalid:8443", "https://box.example.invalid:444/v1"])
    func originsMatchTheMacRule(_ address: String) throws {
        #expect(try DeviceApprovalWire.origin(address: address).hasPrefix("https://box.example.invalid"))
    }

    @Test(arguments: ["http://box.example.invalid", "https://box.example.invalid/p/owner", "https://u:p@box.example.invalid",
                      "https://box.example.invalid:443", "https://[::1]"])
    func unsafeOriginsAreUnavailable(_ address: String) {
        #expect(throws: ManagedControlError.self) { try DeviceApprovalWire.origin(address: address) }
    }

    @Test func canonicalOriginVectorsAgreeWithThePythonBox() throws {
        let path = UpdateVerifierTests.repository.appendingPathComponent("Tests/Fixtures/device_approval_origins.json")
        let cases = try #require(try DeviceApprovalJSON.parse(Data(contentsOf: path)).arrayValue)
        for entry in cases {
            let address = try #require(entry["origin"]?.stringValue)
            if entry["valid"] == .bool(true) {
                #expect(try DeviceApprovalWire.origin(address: address) == address)
            } else {
                #expect(throws: ManagedControlError.self) { try DeviceApprovalWire.origin(address: address) }
            }
        }
    }
}
