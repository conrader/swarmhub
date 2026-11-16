import Foundation
import Testing
@testable import AgentApp

@Test func syntheticTemplateParsingIsTolerantAndComplete() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/synthetic_grok_template.json").standardizedFileURL
    let manifest = try GrokTemplateParser.parse(Data(contentsOf: fixture))
    #expect(manifest.name == "Garden Helper")
    #expect(manifest.title == "Synthetic planning bot")
    #expect(manifest.memories.count == 2)
    #expect(manifest.skills.first?.markdown.contains("crop rotations") == true)
    #expect(manifest.routines.count == 2)
    #expect(manifest.connectorIDs == ["slack", "unknown.synthetic"])
    #expect(manifest.gettingStartedSkill?.isEnabled == false)
}

@Test func templateParserStripsSecretFieldsAndValuesWithoutReportingThem() throws {
    let marker = "not-for-storage-1234567890"
    let json = """
    {"name":"Safe","api_key":"\(marker)","memories":[{"name":"Drop","value":"Bearer \(marker)"},{"name":"Keep","value":"Public synthetic fact"}],"unknown":{"password":"\(marker)"}}
    """.data(using: .utf8)!
    let manifest = try GrokTemplateParser.parse(json)
    let plan = TemplateImportMapper.makePlan(from: manifest)
    #expect(manifest.rejectedSecretCount == 3)
    #expect(manifest.memories.map(\.value) == ["[removed]", "Public synthetic fact"])
    let encodedReport = String(data: try JSONEncoder().encode(plan.report), encoding: .utf8)!
    #expect(!encodedReport.contains(marker))
    #expect(!encodedReport.lowercased().contains("api_key"))
}

@Test @MainActor func templateImportRedactsEveryReviewedSecretShapeFromPersistedBots() throws {
    let secrets = [
        "eyJabcdefgh.ijklmnop.qrstuvwx",
        "github_pat_syntheticMarker123",
        "AKIA1234567890ABCDEF",
        "AIzaabcdefghijklmnopqrstuvwxyz123456789",
        "xapp-syntheticMarker123",
        "https://hooks.slack.com/services/T000/B000/syntheticMarker",
        "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        "Basic c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz",
        "https://syntheticUser:syntheticPass@example.invalid",
        "access_token=syntheticMarker123",
        "client_secret:syntheticMarker123"
    ]
    for secret in secrets {
        let object: [String: Any] = [
            "name": "Safe",
            "persona": "Persona before \(secret) persona after",
            "skills": [["name": "Safe skill", "markdown": "Skill before \(secret) skill after"]],
            "routines": [["name": "Safe routine", "cron": "0 1 * * *", "prompt": "Routine before \(secret) routine after"]],
            "memories": [["name": "Safe memory", "value": "Memory before \(secret) memory after"]],
            "unknown": [["Nested before \(secret) nested after"]]
        ]
        let manifest = try GrokTemplateParser.parse(JSONSerialization.data(withJSONObject: object))
        #expect(manifest.rejectedSecretCount >= 5)
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = []
        _ = store.importTemplate(TemplateImportMapper.makePlan(from: manifest))
        let persisted = String(decoding: try JSONEncoder().encode(store.bots), as: UTF8.self)
        #expect(!persisted.contains(secret))
    }
}

@Test func templateImportRedactsCredentialLikePersonaTextWithoutDiscardingPersona() throws {
    let json = #"{"persona":"Be helpful. Password: never ask the user for it. Keep this guidance."}"#.data(using: .utf8)!
    let manifest = try GrokTemplateParser.parse(json)
    #expect(manifest.instructions.contains("Be helpful."))
    #expect(manifest.instructions.contains("ask the user for it. Keep this guidance."))
    #expect(manifest.instructions.contains("[removed]"))
    let personaRow = TemplateImportMapper.makePlan(from: manifest).report.first { $0.name == "Persona" }
    #expect(personaRow?.status == .mapped)
}

@Test func templateImportKeepsOrdinaryBasicProse() throws {
    let manifest = try GrokTemplateParser.parse(#"{"persona":"Use basic troubleshooting before escalation."}"#.data(using: .utf8)!)
    #expect(manifest.instructions == "Use basic troubleshooting before escalation.")
    #expect(manifest.rejectedSecretCount == 0)
}

@Test @MainActor func templateImportRedactsAuthorizationBasicFromPreviewPersonaAndStore() throws {
    let marker = "c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz"
    let json = #"{"name":"Safe","persona":"Before Authorization: Basic \#(marker) After"}"#.data(using: .utf8)!
    let plan = TemplateImportMapper.makePlan(from: try GrokTemplateParser.parse(json))
    #expect(!plan.manifest.instructions.contains(marker))

    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = []
    let bot = store.importTemplate(plan)
    #expect(!bot.persona.contains(marker))
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(marker))
}

@Test func templateImportRemovesUnterminatedPrivateKeyBlockToEndOfText() throws {
    let firstBodyLine = "VW50ZXJtaW5hdGVkIHN5bnRoZXRpYyBrZXk="
    let trailingBodyLine = "VGhpcyBtdXN0IGFsc28gYmUgcmVtb3ZlZA=="
    let persona = "Keep this.\n-----BEGIN RSA PRIVATE KEY-----\n\(firstBodyLine)\n\(trailingBodyLine)"
    let data = try JSONSerialization.data(withJSONObject: ["persona": persona])
    let manifest = try GrokTemplateParser.parse(data)
    #expect(manifest.instructions == "Keep this.\n[removed]")
    #expect(!manifest.instructions.contains(firstBodyLine))
    #expect(!manifest.instructions.contains(trailingBodyLine))
}

@Test func templateImportRejectsReviewedSecretKeyNames() throws {
    for key in ["auth", "bearer", "jwt", "passphrase", "pwd", "accessKey", "aws_access_key_id", "sessionKey", "webhookUrl", "dsn", "connectionString"] {
        let data = try JSONSerialization.data(withJSONObject: ["name": "Safe", key: "syntheticMarker"])
        #expect(try GrokTemplateParser.parse(data).rejectedSecretCount == 1)
    }
}

