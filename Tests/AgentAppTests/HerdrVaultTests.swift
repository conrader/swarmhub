import Foundation
import Testing
@testable import AgentApp

@Test func vaultRequestDecodesMetadataFromBridge() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let json = """
    {"id":"00112233445566778899aabbccddeeff","bot":"Research",
     "name":"FIXTURE_TOKEN","label":"Reports","description":"Read reports","needs_value":true}
    """
    let request = try decoder.decode(HerdrVault.Request.self, from: Data(json.utf8))
    #expect(request.bot == "Research")
    #expect(request.name == "FIXTURE_TOKEN")
    #expect(request.needsValue)
    let path = try HerdrVault.path(request.id, under: "/api/vault/requests")
    #expect(path == "/api/vault/requests/00112233445566778899aabbccddeeff")
    #expect(throws: HerdrClient.Failure.invalidURL) {
        try HerdrVault.path("../fixture", under: "/api/vault/requests")
    }
}

@Test func vaultDecisionOnlySendsAValueWhenEnteringOne() {
    let new = HerdrVault.Decision.save("synthetic-fixture").body
    #expect(new["action"] as? String == "save")
    #expect(new["value"] as? String == "synthetic-fixture")
    let existing = HerdrVault.Decision.save(nil).body
    #expect(existing["action"] as? String == "save")
    #expect(existing["value"] == nil)
    let repeated = HerdrVault.Decision.allowRepeated(nil).body
    #expect(repeated["action"] as? String == "allow_repeated")
    #expect(repeated["value"] == nil)
    let repeatedNew = HerdrVault.Decision.allowRepeated("synthetic-fixture").body
    #expect(repeatedNew["action"] as? String == "allow_repeated")
    #expect(repeatedNew["value"] as? String == "synthetic-fixture")
    let cancel = HerdrVault.Decision.cancel.body
    #expect(cancel["action"] as? String == "cancel")
    #expect(cancel["value"] == nil)
}
