import CommonCrypto
import Foundation
import Testing
@testable import AgentApp

/// Test-only: produce an Electron safeStorage value `base64("v10" + AES-128-CBC/PKCS7)` under `key`,
/// so the decrypt path can be exercised without any real Grok Bot secret.
private func encryptForTest(_ text: String, key: [UInt8]) throws -> String {
    let plain = Array(text.utf8)
    var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
    var moved = 0
    let iv = [UInt8](repeating: 0x20, count: 16)
    let status = plain.withUnsafeBufferPointer { pt in
        key.withUnsafeBufferPointer { ky in
            iv.withUnsafeBufferPointer { vi in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                        ky.baseAddress, ky.count, vi.baseAddress, pt.baseAddress, pt.count, &out, out.count, &moved)
            }
        }
    }
    #expect(status == kCCSuccess)
    return (Data("v10".utf8) + Data(out[0..<moved])).base64EncodedString()
}

/// P10.0 pure tests: the known-answer vectors in briefs/P10.md (recomputed from the repo's Python on 2026-10-13),
/// plus the credential shape checks. No Keychain, no network, no fixtures from Grok.
private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
private let agent = "00000000-0000-4000-8000-0000000000a1"

// MARK: Checksum (nowMs -> header), machine id "mid"

@Test func checksumMatchesTheVectors() {
    let cases: [(Int64, String)] = [
        (1760000000000, "fn-BnklOmid"), (1760000999999, "fn-BnklOmid"), (1760001000000, "foCCm0RKmid"),
        (1791000000000, "8ers-rKvmid"), (1799999999999, "0u7w7p2nmid"), (1700000000000, "Vfb45Bi9mid"),
        (16777216000000, "paaprLC1mid"),
    ]
    for (nowMs, expected) in cases {
        #expect(GrokChecksum.header(machineID: "mid", nowMs: nowMs) == expected, "nowMs \(nowMs)")
    }
}

// MARK: PBKDF2 + safeStorage

@Test func pbkdf2DerivesTheVectorKeys() throws {
    #expect(hex(try GrokSafeStorage.deriveKey(password: Array("synthetic-pass".utf8))) == "c3b228bd930628aa1baab3f1a0f9911a")
    // The password is the literal ASCII text, never base64-decoded.
    #expect(hex(try GrokSafeStorage.deriveKey(password: Array("c3ludGhldGljLWtleS0wMDAx".utf8))) == "925c50b7bba157915c5626656b2ac8d8")
}

@Test func safeStorageDecryptsTheVectors() throws {
    let keyA = try GrokSafeStorage.deriveKey(password: Array("synthetic-pass".utf8))
    #expect(try GrokSafeStorage.decryptText("djEwLxWA72RiFyJjJwUyVOZUeOfLRjarBACKhRdBmH8/9Hc=", key: keyA) == "synthetic-token-123")

    let keyB = try GrokSafeStorage.deriveKey(password: Array("c3ludGhldGljLWtleS0wMDAx".utf8))
    #expect(try GrokSafeStorage.decryptText("djEwcMZK0Uz8ii0valeCeQOfyQ==", key: keyB) == "synthetic-15-by")
    #expect(try GrokSafeStorage.decryptText("djEwiui0DaFOAR4FzUwOE4bzkRqwvoSkrQXd2fXY0PmmMJg=", key: keyB) == "0123456789abcdef")
}

@Test func safeStorageRejectsAWrongVersionPrefix() throws {
    let key = try GrokSafeStorage.deriveKey(password: Array("synthetic-pass".utf8))
    let v11 = Data("v11xxxx".utf8).base64EncodedString()
    #expect(throws: GrokSafeStorageError.unsupportedVersion) { try GrokSafeStorage.decrypt(v11, key: key) }
}

@Test func scopedValuesAreUnwrappedBeforeDecrypting() throws {
    let key = try GrokSafeStorage.deriveKey(password: Array("c3ludGhldGljLWtleS0wMDAx".utf8))
    #expect(try GrokSafeStorage.decryptText("scoped:v1:any-scope:djEwcMZK0Uz8ii0valeCeQOfyQ==", key: key) == "synthetic-15-by")
    #expect(throws: GrokSafeStorageError.badScopedValue) { try GrokSafeStorage.decrypt("scoped:v1:missing", key: key) }
}

@Test func aWrongKeyIsCaughtByUTF8OrShapeChecks() throws {
    // The right ciphertext with a different key: decryption either fails PKCS7, or passes and is not UTF-8/not a token.
    let wrongKey = try GrokSafeStorage.deriveKey(password: Array("wrong-password".utf8))
    var caught = false
    do {
        let text = try GrokSafeStorage.decryptText("djEwLxWA72RiFyJjJwUyVOZUeOfLRjarBACKhRdBmH8/9Hc=", key: wrongKey)
        caught = !GrokCredentials.tokenSegmentsValid(text) // passed padding + UTF-8 but is not a three-segment token
    } catch { caught = true }
    #expect(caught)
}

// MARK: Protobuf

@Test func listAndPresignEncodeToTheVectors() {
    #expect(hex(GrokProtobuf.varint(300)) == "ac02")
    #expect(hex(GrokProtobuf.varint(500)) == "f403")
    #expect(hex(GrokProtobuf.varint(2928)) == "f016")
    #expect(hex(GrokProtobuf.encodeListRequest(agentID: agent, limit: 500))
            == "0a2430303030303030302d303030302d343030302d383030302d30303030303030303030613120f403")
    #expect(hex(GrokProtobuf.encodeListRequest(agentID: agent, limit: 500, beforeSeq: 2928))
            == "0a2430303030303030302d303030302d343030302d383030302d30303030303030303030613118f01620f403")
    #expect(hex(GrokProtobuf.encodeListRequest(agentID: agent, limit: 1, beforeSeq: 501))
            == "0a2430303030303030302d303030302d343030302d383030302d30303030303030303030613118f5032001")
    #expect(hex(GrokProtobuf.encodePresignRequest(relPaths: ["blobs/abc", "blobs/def"]))
            == "0a09626c6f62732f6162630a09626c6f62732f646566")
}

@Test func responsesDecodeRowsInlineBlobAndOmitted() throws {
    func rowBytes(seq: Int64, body: [UInt8]? = nil, blobHash: String? = nil, entryID: String? = nil, omitted: Bool = false) -> [UInt8] {
        var out = GrokProtobuf.varintField(1, UInt64(seq)) + GrokProtobuf.bytesField(2, Array("message".utf8))
        if let body { out += GrokProtobuf.bytesField(3, body) }
        if let blobHash { out += GrokProtobuf.bytesField(4, Array(blobHash.utf8)) }
        if let entryID { out += GrokProtobuf.bytesField(6, Array(entryID.utf8)) }
        if omitted { out += GrokProtobuf.varintField(7, 1) }
        return out
    }
    let data = GrokProtobuf.bytesField(1, rowBytes(seq: 7, body: Array("{}".utf8), entryID: "e7"))
        + GrokProtobuf.bytesField(1, rowBytes(seq: 6, blobHash: "h", omitted: true))
    let rows = try GrokProtobuf.decodeListResponse(data)
    #expect(rows.count == 2)
    #expect(rows[0].seq == 7 && rows[0].entryKind == "message" && rows[0].body == Array("{}".utf8) && rows[0].entryID == "e7")
    #expect(rows[1].seq == 6 && rows[1].blobHash == "h" && rows[1].body == nil && rows[1].bodyOmitted)

    let presign = GrokProtobuf.bytesField(1, GrokProtobuf.bytesField(1, Array("blobs/abc".utf8)) + GrokProtobuf.bytesField(2, Array("https://e/x".utf8)))
    #expect(try GrokProtobuf.decodePresignResponse(presign) == ["blobs/abc": "https://e/x"])
}

@Test func protobufDecodeFailsClosedOnBadWire() {
    #expect(throws: GrokProtobufError.self) { _ = try GrokProtobuf.parse([0x08, 0xFF]) }        // truncated varint
    #expect(throws: GrokProtobufError.self) { _ = try GrokProtobuf.parse([0x0A, 0x05, 0x01]) }  // length overruns
    #expect(throws: GrokProtobufError.unsupportedWireType(3)) { _ = try GrokProtobuf.parse([0x0B]) } // wire type 3
}

// MARK: Credential shape checks

private func jwt(exp: Double?) -> String {
    let header = GrokChecksum.base64URLNoPadding(Array(#"{"alg":"none"}"#.utf8))
    let claims: [String: Any] = exp.map { ["exp": $0] } ?? [:]
    let payloadData = try! JSONSerialization.data(withJSONObject: claims)
    return "\(header).\(GrokChecksum.base64URLNoPadding([UInt8](payloadData))).sig"
}

@Test func tokenSegmentAndExpiryRules() {
    #expect(GrokCredentials.tokenSegmentsValid(jwt(exp: 1)))
    #expect(!GrokCredentials.tokenSegmentsValid("not-a-jwt"))
    #expect(!GrokCredentials.tokenSegmentsValid("only.two"))
    #expect(!GrokCredentials.tokenSegmentsValid("has.bad char.here"))

    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(GrokCredentials.tokenExpired(jwt(exp: 999_000), now: now))                     // past
    #expect(!GrokCredentials.tokenExpired(jwt(exp: 2_000_000), now: now))                  // future
    #expect(GrokCredentials.tokenExpired(jwt(exp: 1_000_030), now: now, margin: 60))       // inside the 60 s margin
    #expect(!GrokCredentials.tokenExpired(jwt(exp: 1_000_090), now: now, margin: 60))      // outside it
    #expect(!GrokCredentials.tokenExpired("not-a-jwt", now: now))                          // non-JWT: not treated as expired
    #expect(!GrokCredentials.tokenExpired(jwt(exp: nil), now: now))                        // no exp claim
}

@Test func accountBindingUsesSha256OfTheSlotValue() {
    let slot = "account-slot-value"
    let digest = GrokCredentials.sha256Hex(Array(slot.utf8))
    #expect(GrokCredentials.accountBindingHolds(activeAccountID: digest.uppercased(), accountSlotValue: slot))
    #expect(!GrokCredentials.accountBindingHolds(activeAccountID: "deadbeef", accountSlotValue: slot))
}

@Test func machineIDAndTeamIDRulesFromSyntheticSecrets() throws {
    // Build a synthetic secrets file whose three values encrypt under a known key, then decrypt and shape-check.
    let key = try GrokSafeStorage.deriveKey(password: Array("synthetic-pass".utf8))
    let token = jwt(exp: Date().timeIntervalSince1970 + 3600)
    let encrypted = GrokSecretsFile.EncryptedAccount(
        activeAccountID: "acct",
        accessToken: try encryptForTest(token, key: key),
        teamID: try encryptForTest("42", key: key),
        machineID: try encryptForTest("machine-123", key: key))
    let creds = try GrokCredentials.decrypt(from: encrypted, key: key, now: Date())
    #expect(creds.token.reveal() == token)
    #expect(creds.machineID.reveal() == "machine-123")
    #expect(creds.teamID == "42")

    // A non-positive / non-numeric team id is dropped; a machine id over 127 chars is dropped.
    let zeroTeam = GrokSecretsFile.EncryptedAccount(activeAccountID: "a", accessToken: try encryptForTest(token, key: key),
                                                    teamID: try encryptForTest("0", key: key),
                                                    machineID: try encryptForTest(String(repeating: "x", count: 200), key: key))
    let creds2 = try GrokCredentials.decrypt(from: zeroTeam, key: key, now: Date())
    #expect(creds2.teamID == nil && creds2.machineID.reveal().isEmpty)
}

@Test func expiredTokenIsRejectedByDecrypt() throws {
    let key = try GrokSafeStorage.deriveKey(password: Array("synthetic-pass".utf8))
    let expired = GrokSecretsFile.EncryptedAccount(activeAccountID: "a",
                                                   accessToken: try encryptForTest(jwt(exp: 1), key: key), teamID: nil, machineID: nil)
    #expect(throws: GrokCredentialsError.tokenExpired) { _ = try GrokCredentials.decrypt(from: expired, key: key, now: Date()) }
}
