import CryptoKit
import Foundation
import Testing
@testable import AgentApp

/// A separate injectable approval vault; these tests never access the system Keychain.
final class MemoryApprovalKeys: DeviceApprovalKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var seeds: [String: Data] = [:]
    var refuseRead = false
    var refuseWrite = false
    var discardWrite = false
    func read(account: String) throws -> Data? {
        try lock.withLock {
            if refuseRead { throw DeviceApprovalIdentity.Failure.storage }
            return seeds[account]
        }
    }
    func insert(_ seed: Data, account: String) throws {
        try lock.withLock {
            if refuseWrite { throw DeviceApprovalIdentity.Failure.storage }
            if !discardWrite { seeds[account] = seed }
        }
    }
}

func deviceFixture(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/" + path)
}

func testApprovalIdentity() throws -> DeviceApprovalIdentity {
    let keys = try #require(try DeviceApprovalJSON.parse(Data(contentsOf: deviceFixture("release-bundles/TEST-device-keys.json")))["keys"]?.arrayValue)
    let key = try #require(keys.first)
    return try DeviceApprovalIdentity(seed: approvalHex(try #require(key["seed"]?.stringValue)), keyID: "TEST-device-1")
}

func approvalHex(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let end = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<end], radix: 16)!)
        index = end
    }
    return data
}

struct DeviceApprovalIdentityTests {
    @Test func separateApprovalNamespacePersistsPerBoxAndNeverReadsOpenClaw() throws {
        let keys = MemoryApprovalKeys()
        let box = "https://box.example.invalid"
        // Even with an OpenClaw seed in the injected store, approval loading only addresses approval-v2.*.
        let gateway = try GatewayIdentity(seed: Data(repeating: 42, count: 32))
        try keys.insert(Data(repeating: 42, count: 32), account: GatewayIdentity.account(gatewayID: box))
        let first = try DeviceApprovalIdentity.loadOrCreate(box: box, store: keys)
        let again = try DeviceApprovalIdentity.loadOrCreate(box: box, store: keys)
        let other = try DeviceApprovalIdentity.loadOrCreate(box: "https://other.example.invalid", store: keys)
        #expect(first.publicKey == again.publicKey && first.keyID == again.keyID)
        #expect(first.publicKey != other.publicKey)
        #expect(first.publicKey != DeviceApprovalWire.hex(Base64URL.decode(gateway.publicKey)!))
        #expect(DeviceApprovalIdentity.account(box: box) != GatewayIdentity.account(gatewayID: box))
        #expect(ApprovalKeychainStore.service == "com.swarmhub.device-approvals.v2")
        #expect(!String(reflecting: first).contains("seed"))
        #expect(first.customMirror.children.count == 2)
    }

    @Test func damagedInaccessibleAndUnverifiedStorageFailsClosed() throws {
        let keys = MemoryApprovalKeys()
        keys.refuseRead = true
        #expect(throws: DeviceApprovalIdentity.Failure.self) { try DeviceApprovalIdentity.loadOrCreate(box: "box", store: keys) }
        keys.refuseRead = false; keys.refuseWrite = true
        #expect(throws: DeviceApprovalIdentity.Failure.self) { try DeviceApprovalIdentity.loadOrCreate(box: "box", store: keys) }
        keys.refuseWrite = false; keys.discardWrite = true
        #expect(throws: DeviceApprovalIdentity.Failure.self) { try DeviceApprovalIdentity.loadOrCreate(box: "box", store: keys) }
        keys.discardWrite = false
        try keys.insert(Data([1, 2]), account: DeviceApprovalIdentity.account(box: "box"))
        #expect(throws: DeviceApprovalIdentity.Failure.self) { try DeviceApprovalIdentity.loadOrCreate(box: "box", store: keys) }
        #expect(try keys.read(account: DeviceApprovalIdentity.account(box: "box")) == Data([1, 2]))
    }

    @Test func everyP5aPayloadMatchesCanonicalBytesAndVerifiesCryptoKitFixture() throws {
        let document = try DeviceApprovalJSON.parse(Data(contentsOf: deviceFixture("device_approval_protocol.json")))
        let cases = try #require(document["cases"]?.arrayValue).filter { $0["signature_valid"] != nil }
        let keys = try #require(try DeviceApprovalJSON.parse(Data(contentsOf: deviceFixture("release-bundles/TEST-device-keys.json")))["keys"]?.arrayValue)
        let path = deviceFixture("release-bundles/TEST-mac-device-signatures.json")
        if ProcessInfo.processInfo.environment["SWARMHUB_WRITE_DEVICE_FIXTURE"] == "1" {
            let output = try cases.map { entry -> JSONValue in
                let vector = try DeviceApprovalJSON.parse(Data(try #require(entry["request"]?.stringValue).utf8))
                let body = try #require(vector["signed"]?.objectValue)
                let keyID = try #require(body["key_id"]?.stringValue)
                let key = try #require(keys.first { $0["key_id"] == .string(keyID) })
                let identity = try DeviceApprovalIdentity(seed: approvalHex(try #require(key["seed"]?.stringValue)), keyID: keyID)
                // Sign once. CryptoKit may randomize Ed25519; the envelope owns this signature.
                let raw = try DeviceApprovalWire.envelope(body, identity: identity)
                let envelope = try DeviceApprovalJSON.parse(raw)
                return .object(["id": entry["id"]!, "key_id": .string(keyID), "public_key": .string(identity.publicKey),
                    "canonical": .string(String(decoding: try DeviceApprovalWire.canonical(.object(body)), as: UTF8.self)),
                    "message": .string(String(decoding: try DeviceApprovalWire.message(body), as: UTF8.self)),
                    "signature": try #require(envelope["signature"]), "envelope": .string(String(decoding: raw, as: UTF8.self))])
            }
            try DeviceApprovalWire.canonical(.object(["schema": .string("swarmhub/mac-device-signatures/2"),
                                                      "cases": .array(output)])).write(to: path, options: .atomic)
        }
        // The same validation runs after writing and on every plain swift test, without re-signing.
        let reference = try DeviceApprovalJSON.parse(Data(contentsOf: path))
        #expect(reference["schema"] == .string("swarmhub/mac-device-signatures/2"))
        let stored = try #require(reference["cases"]?.arrayValue)
        #expect(stored.count == 38)
        #expect(stored.map { $0["id"] } == cases.map { $0["id"] })
        for (entry, fixture) in zip(cases, stored) {
            let vector = try DeviceApprovalJSON.parse(Data(try #require(entry["request"]?.stringValue).utf8))
            let body = try #require(vector["signed"]?.objectValue)
            let keyID = try #require(body["key_id"]?.stringValue)
            let key = try #require(keys.first { $0["key_id"] == .string(keyID) })
            let publicHex = try #require(key["ed25519_pub"]?.stringValue)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: approvalHex(publicHex))
            let canonical = try DeviceApprovalWire.canonical(.object(body))
            let message = try DeviceApprovalWire.message(body)
            #expect(fixture["key_id"] == .string(keyID))
            #expect(fixture["public_key"] == .string(publicHex))
            #expect(fixture["canonical"] == .string(String(decoding: canonical, as: UTF8.self)))
            #expect(fixture["message"] == .string(String(decoding: message, as: UTF8.self)))
            let signature = approvalHex(try #require(fixture["signature"]?.stringValue))
            #expect(publicKey.isValidSignature(signature, for: message))
            let envelope = try DeviceApprovalJSON.parse(Data(try #require(fixture["envelope"]?.stringValue).utf8))
            #expect(envelope["signed"] == .object(body))
            #expect(publicKey.isValidSignature(approvalHex(try #require(envelope["signature"]?.stringValue)), for: message))
            #expect(publicKey.isValidSignature(approvalHex(try #require(vector["signature"]?.stringValue)), for: message)
                    == (entry["signature_valid"] == .bool(true)))
        }
    }

    @Test func strictJSONAndJCSRejectInvalidSignedValues() throws {
        for raw in ["{\"a\":1,\"a\":2}", "{\"a\":-0}", "{\"a\":9007199254740992}", "{\"a\":\"\\ud800\"}", "\u{FEFF}{}"] {
            #expect(throws: (any Error).self) { try DeviceApprovalJSON.parse(Data(raw.utf8)) }
        }
        for value in [JSONValue.null, .double(1.0), .object(["é": .int(1)]), .int(9_007_199_254_740_992)] {
            #expect(throws: ManagedControlError.self) { try DeviceApprovalWire.canonical(value) }
        }
        #expect(throws: ManagedControlError.self) {
            try DeviceApprovalClient.decodeRecord(.object(["spec": .object(["amount": .double(1.0)])]))
        }
        let value = JSONValue.object(["z": .string("/☃café\u{2028}\n\u{0000}"), "a": .bool(false)])
        #expect(String(decoding: try DeviceApprovalWire.canonical(value), as: UTF8.self) == "{\"a\":false,\"z\":\"/☃café\u{2028}\\n\\u0000\"}")
        #expect(try DeviceApprovalWire.message(["approved": .bool(true)]) != DeviceApprovalWire.message(["approved": .bool(true)], read: true))
        for address in ["http://box.invalid", "https://box.invalid:443", "https://box.invalid:0444", "https://box..invalid", "https://[::1]"] {
            #expect(throws: (any Error).self) { try DeviceApprovalWire.origin(address: address) }
        }
    }
}

extension DeviceApprovalIdentityTests {
    @Test func cutoverRoutingIsStickyAndCorruptAttemptsFailClosed() throws {
        let defaults = isolatedDefaults(), origin = "https://box.example.invalid"
        let settings = DeviceApprovalSettings(defaults: defaults)
        #expect(!settings.isRequired(origin))
        settings.confirmOperatorCutover(origin)
        let prefix = "approvals.v2." + DeviceApprovalWire.digest(Data(origin.utf8))
        defaults.set(false, forKey: prefix + ".required")
        #expect(DeviceApprovalSettings(defaults: defaults).isRequired(origin))
        defaults.set("damaged", forKey: prefix + ".task." + String(repeating: "a", count: 32))
        #expect(throws: ManagedControlError.self) {
            try settings.attempt(origin: origin, task: "task." + String(repeating: "a", count: 32))
        }
    }
}

extension DeviceApprovalIdentityTests {
    @Test func challengeMustKeepEveryBoxBindingAndFullSpecDigest() throws {
        let doc = try DeviceApprovalJSON.parse(Data(contentsOf: deviceFixture("device_approval_protocol.json")))
        let state = try #require(doc["state"]?.objectValue)
        let binding = try #require(state["nonces"]?.objectValue?.values.first?["binding"]?.objectValue)
        let identity = try testApprovalIdentity()
        let record = ManagedRecord(id: state["task"]!.stringValue!, fingerprint: "TEST-v1-digest", gate: "owner",
            status: "awaiting-owner", decider: "owner", spec: .init(fields: state["spec"]!.objectValue!))
        try DeviceApprovalWire.validateChallenge(binding, identity: identity, origin: state["origin"]!.stringValue!,
            profile: "owner", task: record.id, record: record)
        for field in binding.keys {
            var damaged = binding
            damaged[field] = .null
            #expect(throws: (any Error).self) {
                try DeviceApprovalWire.validateChallenge(damaged, identity: identity, origin: state["origin"]!.stringValue!,
                    profile: "owner", task: record.id, record: record)
            }
        }
        var extended = binding; extended["extra"] = .bool(true)
        #expect(throws: ManagedControlError.self) {
            try DeviceApprovalWire.validateChallenge(extended, identity: identity, origin: state["origin"]!.stringValue!,
                profile: "owner", task: record.id, record: record)
        }
    }
}
