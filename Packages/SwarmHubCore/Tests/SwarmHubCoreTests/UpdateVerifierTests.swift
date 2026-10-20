import Foundation
import CryptoKit
import Testing
@testable import SwarmHubCore

struct UpdateVerifierTests {
    // Also read by scripts/test_swift_update_vectors.py: one catalogue, no copied expectations.
    static let vectorFixture = "Tests/Fixtures/release-bundles/vectors.json"
    static var repository: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    static var fixtures: URL { repository.appendingPathComponent(vectorFixture).deletingLastPathComponent() }

    struct Catalog: Decodable {
        let cases: [Vector]
        let jcs: [CanonicalVector]
    }
    struct CanonicalVector: Decodable {
        let id: String
        let input: String
        let canonical: String?
        let error: Bool?
    }
    struct Vector: Decodable {
        let id: String
        let inputs: Inputs
        let expect: UpdateVerdict
    }
    struct Inputs: Decodable {
        let pins: String, keys: String, index: String, manifest: String
        let channel: String, now: String, installID: String
        let floors: [String: Int64]
        let consumer: Consumer
        let revokedKeyIDs: [String]
        let limits: [String: Int]
        enum CodingKeys: String, CodingKey {
            case pins, keys, index, manifest, channel, now, floors, consumer, limits
            case installID = "install_id"
            case revokedKeyIDs = "revoked_key_ids"
        }
    }
    struct Consumer: Decodable { let platform: String; let versions: [String: String] }

    static func catalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: repository.appendingPathComponent(vectorFixture)))
    }
    func read(_ path: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(path)) }
    func run(_ vector: Vector, fetched: inout [String]) throws -> UpdateVerification {
        let i = vector.inputs
        var limits = UpdateLimits()
        limits.maxSignedBytes = try #require(i.limits["max_signed_bytes"])
        limits.maxBlobSize = try #require(i.limits["max_blob_size"])
        limits.maxEntries = try #require(i.limits["max_entries"])
        limits.maxFileSize = try #require(i.limits["max_file_size"])
        limits.maxTotalSize = try #require(i.limits["max_total_size"])
        limits.maxPathBytes = try #require(i.limits["max_path_bytes"])
        limits.maxDepth = try #require(i.limits["max_depth"])
        let floors = UpdateFloors(keysVersion: try #require(i.floors["keys_version"]),
            indexSequence: try #require(i.floors["index_seq"]), bundleVersion: try #require(i.floors["bundle_version"]))
        return try UpdateVerifier.verify(pins: read(i.pins), keys: read(i.keys), index: read(i.index),
            fetchManifest: { _ in fetched.append("manifest"); return try read(i.manifest) },
            fetchBlob: { c in fetched.append(c.name); return try read("blobs/sha256/" + c.sha256) },
            channel: i.channel, now: i.now, floors: floors,
            consumer: UpdateConsumer(platform: i.consumer.platform, versions: i.consumer.versions),
            installID: i.installID, revokedKeyIDs: Set(i.revokedKeyIDs), limits: limits)
    }

    @Test func everyReleaseVector() throws {
        let catalog = try Self.catalog()
        #expect(!catalog.cases.isEmpty)
        for vector in catalog.cases {
            var fetched: [String] = []
            let result = try run(vector, fetched: &fetched)
            #expect(result.verdict == vector.expect, "\(vector.id)")
            if result.verdict.verdict == "accept" {
                #expect(result.manifest != nil, "\(vector.id)")
                #expect(Set(result.blobs.keys) == Set(result.verdict.apply ?? []), "\(vector.id)")
                #expect(fetched == ["manifest"] + (result.verdict.apply ?? []), "\(vector.id)")
            } else {
                #expect(result.manifest == nil && result.blobs.isEmpty, "\(vector.id)")
                if ["pins", "keys", "index"].contains(result.verdict.stage) { #expect(fetched.isEmpty) }
            }
            if vector.id == "archive-oversize-blob" { #expect(fetched == ["manifest"]) }
        }
    }

    @Test func everyCanonicalVector() throws {
        let catalog = try Self.catalog()
        #expect(!catalog.jcs.isEmpty)
        for vector in catalog.jcs {
            if vector.error == true {
                #expect(throws: JCS.Invalid.self) { try JCS.parse(Data(vector.input.utf8)) }
            } else {
                let expected = try #require(vector.canonical)
                #expect(try JCS.canonical(JCS.parse(Data(vector.input.utf8))) == Data(expected.utf8), "\(vector.id)")
            }
        }
    }

    @Test func additionalCanonicalEdges() throws {
        let bad = ["-9007199254740992", "9007199254740992", "-0", "0.0", "1E0", "+1", "01", "Infinity",
                   "null", "[1,]", "{\"a\":1,\"\\u0061\":2}", "\"\\udc00\"", "\"\\ud800x\"",
                   "\u{FEFF}{}", "{}true", String(repeating: "[", count: 33) + "1" + String(repeating: "]", count: 33)]
        for text in bad { #expect(throws: JCS.Invalid.self) { try JCS.parse(Data(text.utf8)) } }
        #expect(throws: JCS.Invalid.self) { try JCS.parse(Data([34, 0xC0, 0xAF, 34])) }
        #expect(throws: JCS.Invalid.self) { try JCS.canonical(.integer(Int64.min)) }
        #expect(throws: JCS.Invalid.self) { try JCS.canonical(.object(["é": .bool(true)])) }
        let text = "{\"z\":-9007199254740991,\"Z\":0,\"a\":\"\\u0000\\u000b\\u2028\\u2029e\\u0301\",\"A\":true}"
        let expected = "{\"A\":true,\"Z\":0,\"a\":\"\\u0000\\u000b\u{2028}\u{2029}e\u{0301}\",\"z\":-9007199254740991}"
        #expect(try JCS.canonical(JCS.parse(Data(text.utf8))) == Data(expected.utf8))
        let deepest = String(repeating: "[", count: 32) + "1" + String(repeating: "]", count: 32)
        #expect(try JCS.canonical(JCS.parse(Data(deepest.utf8))) == Data(deepest.utf8))
    }

    @Test func archivePathsLinksAndModes() throws {
        for path in ["../a.md", "/a.md", "a/../../b", "a//b", "a/./b", "a\\b", "a.md\n", "", "é.md"] {
            #expect(!ArchiveRules.safeRelative(path))
            #expect(throws: ArchiveRules.Invalid(reason: "archive_unsafe_path")) {
                try ArchiveRules.check(archive(name: path), kind: "skill")
            }
        }
        for flag in [UInt8(49), 50] {
            #expect(throws: ArchiveRules.Invalid(reason: "archive_link")) {
                try ArchiveRules.check(archive(name: "safe.md", flag: flag), kind: "skill")
            }
        }
        for flag in [UInt8(51), 52, 54] {
            #expect(throws: ArchiveRules.Invalid(reason: "archive_special_file")) {
                try ArchiveRules.check(archive(name: "safe.md", flag: flag), kind: "skill")
            }
        }
        #expect(throws: ArchiveRules.Invalid(reason: "archive_bad_mode")) {
            try ArchiveRules.check(archive(name: "safe.md", mode: 0o777), kind: "skill")
        }
        #expect(try !ArchiveRules.check(archive(name: "docs/README.md"), kind: "skill").needsCode)
        #expect(try ArchiveRules.check(archive(name: "script.py"), kind: "skill").needsCode)
        #expect(try ArchiveRules.check(archive(name: "README.md", mode: 0o755), kind: "skill").needsCode)
        #expect(try !ArchiveRules.check(archive(name: "..md"), kind: "skill").needsCode)
        #expect(try ArchiveRules.check(archive(name: ".md"), kind: "skill").needsCode)
        #expect(try ArchiveRules.check(archive(name: "notes."), kind: "skill").needsCode)
        #expect(throws: ArchiveRules.Invalid(reason: "archive_malformed")) {
            try ArchiveRules.check(Data(repeating: 0, count: 512), kind: "skill")
        }
    }

    @Test func malformedSchemasPrecedeSignatureFailures() throws {
        let limits = UpdateLimits()
        let floors = UpdateFloors(keysVersion: 1, indexSequence: 4, bundleVersion: 10)
        let keys = try KeyManifest.verify(pins: read("keys/pins.json"), manifest: read("keys/keys-2.json"),
                                          floors: floors, limits: limits)
        let shape = UpdateShape(stage: "index")
        let envelope = try shape.object(JCS.parse(read("channels/stable.json")))
        let signed = try shape.object(envelope["signed"])
        let mutations: [String: JCS.Value] = ["seq": .bool(true), "lines": .array([.integer(1)]),
            "expires": .string("2026-02-30T12:00:00Z"), "channel": .string("stable\n")]
        for (field, bad) in mutations {
            var body = signed
            body[field] = bad
            var changed = envelope
            changed["signed"] = .object(body) // deliberately retains the now-invalid signature
            do {
                _ = try ChannelIndex.verify(JCS.canonical(.object(changed)), keys: keys, channel: "stable",
                    now: "2026-10-20T12:00:00Z", floors: floors, revoked: [], limits: limits)
                Issue.record("Malformed index accepted: \(field)")
            } catch let error as UpdateRejection {
                #expect(error.stage == "index" && error.reason == "schema_invalid")
            }
        }
        for bad in [Data("{\"a\":1,\"a\":2}".utf8), Data("[]".utf8), Data("null".utf8), Data([0xff])] {
            do {
                _ = try updateEnvelope(bad, stage: "keys", limits: limits)
                Issue.record("Malformed envelope accepted")
            } catch let error as UpdateRejection {
                #expect(error.stage == "keys" && error.reason == "schema_invalid")
            }
        }
    }

    @Test func testKeySignaturesBindCanonicalBytesAndDomain() throws {
        let s = UpdateShape(stage: "keys")
        let listing = try s.object(JCS.parse(read("keys/TEST-keys.json")))
        let entries = try s.array(listing["keys"])
        let entry = try #require(entries.first { value in
            guard case .object(let key) = value else { return false }
            return key["key_id"] == .string("TEST-release-1")
        })
        let key = try s.object(entry)
        let publicHex = try s.text(key["ed25519_pub"], pattern: "[0-9a-f]{64}")
        let seed = try s.text(key["seed"], pattern: "[0-9a-f]{64}")
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: hexBytes(seed))
        let signed: UpdateObject = ["z": .integer(JCS.maxInteger), "a": .string("資料 e\u{0301} 😀")]
        let canonical = try JCS.canonical(.object(signed))
        let message = Data("swarmhub-signature/1\n".utf8) + canonical
        let signature = try privateKey.signature(for: message)
        func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        func verifies(_ bytes: Data) -> Bool {
            validUpdateSignature(UpdateSignature(keyID: "TEST-release-1", hex: hex(bytes)), publicHex: publicHex, signed: signed)
        }
        #expect(verifies(signature))
        #expect(try !verifies(privateKey.signature(for: canonical)))
        #expect(!validUpdateSignature(UpdateSignature(keyID: "TEST-release-1", hex: hex(signature)),
                                     publicHex: publicHex, signed: ["a": .string("changed")]))
        var highScalar = Array(signature)
        highScalar[63] |= 0x80
        #expect(!verifies(Data(highScalar)))
        var invalidPoint = Array(signature)
        invalidPoint.replaceSubrange(0..<32, with: [UInt8](repeating: 0xff, count: 32))
        #expect(!verifies(Data(invalidPoint)))
    }

    @Test func unavailableProviderPropagatesWithoutAResult() throws {
        enum Unavailable: Error { case fixture }
        let pins = try read("keys/pins.json"), keys = try read("keys/keys-2.json"), index = try read("channels/stable.json")
        #expect(throws: Unavailable.self) {
            try UpdateVerifier.verify(pins: pins, keys: keys, index: index,
                fetchManifest: { _ in throw Unavailable.fixture },
                fetchBlob: { _ in Issue.record("Blob fetched before manifest verified"); throw Unavailable.fixture },
                channel: "stable", now: "2026-10-20T12:00:00Z",
                floors: UpdateFloors(keysVersion: 1, indexSequence: 4, bundleVersion: 10),
                consumer: UpdateConsumer(platform: "ios", versions: ["app": "0.6.2", "ui_catalog": "1.3", "config_schema": "2"]),
                installID: "TEST-install-0001")
        }
    }

    /// Synthetic in-memory ustar, including deliberately unsafe names. Never extracts anything.
    func archive(name: String, flag: UInt8 = 48, mode: Int = 0o644) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], _ start: Int) { header.replaceSubrange(start..<start + bytes.count, with: bytes) }
        func octal(_ number: Int, _ width: Int) -> [UInt8] {
            let digits = String(number, radix: 8)
            return Array((String(repeating: "0", count: width - 1 - digits.count) + digits + "\0").utf8)
        }
        put(Array(name.utf8), 0)
        put(octal(mode, 8), 100)
        put(octal(0, 12), 124)
        put([UInt8](repeating: 32, count: 8), 148)
        header[156] = flag
        put(Array("ustar\0".utf8), 257)
        put(Array("00".utf8), 263)
        let sum = header.reduce(0) { $0 + Int($1) }
        let digits = String(sum, radix: 8)
        put(Array((String(repeating: "0", count: 6 - digits.count) + digits + "\0 ").utf8), 148)
        return Data(header + [UInt8](repeating: 0, count: 1024))
    }
}
