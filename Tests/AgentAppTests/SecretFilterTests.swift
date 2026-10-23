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
    // A JWT right after a dash still matches; only the header may not run on through a further `-eyJ`.
    #expect(SecretFilter.redacted("x -eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlMTIz y") == "x -[removed] y")
}
