import Foundation
import Testing
@testable import AgentApp

@Test func secretFilterKeepsAttributionKeysAndDropsSecretNamedOnes() {
    var rejected = 0
    let input: [String: Any] = ["author": "owner-1", "authored_at": "2026-10-23", "authToken": "syntheticMarker", "nested": ["Pwd": "x"]]
    let clean = SecretFilter.sanitize(input, rejected: &rejected) as? [String: Any]
    #expect(clean?["author"] as? String == "owner-1")
    #expect(clean?["authored_at"] as? String == "2026-10-23")
    #expect(clean?["authToken"] == nil)
    #expect((clean?["nested"] as? [String: Any])?.isEmpty == true)
    #expect(rejected == 2)
    for key in ["auth", "bearer", "jwt", "passphrase", "pwd", "accessKey", "aws_access_key_id", "sessionKey", "webhookUrl", "dsn", "connectionString"] {
        #expect(SecretFilter.isSecretKey(key), "\(key)")
    }
}

@Test func secretFilterCountsEachReplacementOnceUnderItsCategory() {
    var counts: [String: Int] = [:]
    let text = SecretFilter.redact("Authorization: Basic dXNlcjpwYXNz, token=a TOKEN=b, akia1234567890abcdef", replacement: "#", counts: &counts)
    // The Basic pass runs first; `Authorization: #,` is then an assignment in its own right.
    #expect(text == "# # # #")
    #expect(counts == ["basic_auth": 1, "credential_assignment": 3, "aws_key": 1])
    #expect(SecretFilter.redact("token=a token=b").count == 2)
    #expect(SecretFilter.redact("").count == 0)
}

@Test func encodedCandidatesAreRedactedOnlyWhenTheDecodedTextIsCredentialShaped() {
    #expect(SecretFilter.isCredentialShaped("syntheticUser:syntheticPass"))
    #expect(SecretFilter.isCredentialShaped(" api_key=x "))
    #expect(!SecretFilter.isCredentialShaped("just words"))
    #expect(SecretFilter.redacted("a%20b and 50%off") == "a%20b and 50%off")              // decodes, but not a credential
    #expect(SecretFilter.redacted("aGVsbG8gd29ybGQgaGVsbG8gd29ybGQ=") == "aGVsbG8gd29ybGQgaGVsbG8gd29ybGQ=")  // "hello world hello world"
    #expect(SecretFilter.redacted("u=syntheticUser%3AsyntheticPass") == "[removed]")
    // A JWT right after a dash goes with the dash: both belong to one dot-separated part.
    #expect(SecretFilter.redacted("x -eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlMTIz y") == "x [removed] y")
}

@Test func signedJWTsAreRedactedWhole() {
    // Synthetic HMAC-signed JWTs (mirrors test_export_grokbot.py). The first header holds `-eYj`, which 019e27f's
    // pattern refused to run through; the second's header alone decodes to `{"alg":"HS256"}`, which the encoded pass
    // took on its own and left the signature behind.
    let dashHeader = "eyJhbGciOiJIUzI1NiIsImtpZCI6Iueku-eYj-WsteGVtOmQuOiLjeaDs-W1l-WGjuaytSJ9"
        + ".eyJzdWIiOiJzeW50aGV0aWMifQ.nWK2gTy6gDmUnOnp8Y4k0uZORbhnh8pKa5ihimxQfZk"
    let shortHeader = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ.-0SNT8mfIIN8HLVsA6QX9pjgVs_dM3-EXDhJ_L3qvTA"
    for jwt in [dashHeader, shortHeader] {
        var counts: [String: Int] = [:]
        #expect(SecretFilter.redact("x \(jwt) y", counts: &counts) == "x [removed] y", "\(jwt)")
        #expect(counts == ["jwt": 1], "\(jwt)")
    }
    // Any `eyJ` in a part counts, as on main, and a dotted run holding a JWT goes whole.
    #expect(SecretFilter.redacted("a-\(shortHeader)") == "[removed]")
    #expect(SecretFilter.redacted("eyJxxxxxxxx.yyyyyyyy.\(dashHeader).") == "[removed].")
    var redact = GrokRedactor()
    #expect(redact("key \(dashHeader) end") == "key [REDACTED] end")
}
