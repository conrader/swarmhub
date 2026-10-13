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

@Test func templateMappingReportsUnsupportedItemsAndDisablesCron() throws {
    let json = #"{"name":"Fixture","routines":[{"name":"Cron","prompt":"Do it","schedule":"0 9 * * *"},{"name":"Hook","prompt":"Do it","trigger":"event.x"}],"plugins":["slack","missing.id"]}"#.data(using: .utf8)!
    let plan = TemplateImportMapper.makePlan(from: try GrokTemplateParser.parse(json))
    #expect(plan.routines.count == 1)
    #expect(plan.routines.first?.isEnabled == false)
    #expect(plan.routines.first?.prompt == "Do it")
    #expect(plan.mappedConnectorIDs == ["slack"])
    #expect(plan.report.contains { $0.name == "Hook" && $0.status == .unsupported && $0.reason.contains("not carried over") })
    #expect(plan.report.contains { $0.name == "missing.id" && $0.status == .unsupported })
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
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false)
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
    let store = AppStore(storeURL: url, autoConfigureHermes: false)
    store.bots = []
    let bot = store.importTemplate(plan)
    #expect(!bot.persona.contains(marker))
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(marker))
}

@Test func templateImportHidesHermesProfileWhenNotConfigured() throws {
    let manifest = try GrokTemplateParser.parse(#"{"name":"Safe"}"#.data(using: .utf8)!)
    let plan = TemplateImportMapper.makePlan(from: manifest, hermesConfigured: false)
    #expect(!plan.report.contains { $0.name == "Hermes profile" })
}

@Test @MainActor func templateImportRemovesWholePrivateKeyBlockFromPreviewStoreAndHermesPersona() throws {
    let configurationKey = "hermesBaseURL"
    let previousConfiguration = UserDefaults.standard.object(forKey: configurationKey)
    defer {
        if let previousConfiguration { UserDefaults.standard.set(previousConfiguration, forKey: configurationKey) }
        else { UserDefaults.standard.removeObject(forKey: configurationKey) }
    }
    UserDefaults.standard.set("http://127.0.0.1:8642/v1", forKey: configurationKey)
    let bodyLines = [
        "VGhpcyBpcyBhIHN5bnRoZXRpYyBrZXkgYm9keS4=",
        "U2Vjb25kIHN5bnRoZXRpYyBiYXNlNjQgbGluZS4=",
        "VGhpcmQgc3ludGhldGljIGJhc2U2NCBsaW5lLg=="
    ]
    let block = (["-----BEGIN PGP PRIVATE KEY BLOCK-----"] + bodyLines + ["-----END PGP PRIVATE KEY BLOCK-----"]).joined(separator: "\n")
    let object = ["name": "Safe", "persona": "Before\n\(block)\nAfter"]
    let plan = TemplateImportMapper.makePlan(from: try GrokTemplateParser.parse(JSONSerialization.data(withJSONObject: object)), hermesConfigured: true)
    for line in bodyLines { #expect(!plan.manifest.instructions.contains(line)) }
    #expect(plan.manifest.instructions.contains("Before")); #expect(plan.manifest.instructions.contains("After"))

    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false)
    store.bots = []
    let bot = store.importTemplate(plan)
    #expect(bot.backend == .hermes); #expect(bot.persona == plan.manifest.instructions)
    let saved = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    for line in bodyLines {
        #expect(!bot.persona.contains(line))
        #expect(!saved.contains(line))
    }
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

@Test func legacyBotStoreFixtureDecodesWithoutTemplateImportFields() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/legacy_store_without_template_import_fields.json").standardizedFileURL
    let bots = try JSONDecoder().decode([Bot].self, from: Data(contentsOf: fixture))
    #expect(bots.count == 1)
    #expect(bots[0].importedMemories.isEmpty)
    #expect(bots[0].importedSkills.isEmpty)
    #expect(bots[0].requestedConnectorIDs.isEmpty)
    #expect(bots[0].gettingStartedSkill == nil)
    #expect(bots[0].routines.isEmpty)
}

@Test @MainActor func previewPlanDoesNotCreateBotUntilExplicitImport() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false)
    store.bots = []
    let manifest = try GrokTemplateParser.parse(##"{"name":"Only after confirm","skills":[{"name":"S","markdown":"# S"}],"routines":[{"name":"C","cron":"0 1 * * *"}]}"##.data(using: .utf8)!)
    let plan = TemplateImportMapper.makePlan(from: manifest)
    #expect(store.bots.isEmpty)
    let bot = store.importTemplate(plan)
    #expect(store.bots.count == 1)
    #expect(bot.importedSkills.first?.markdown == "# S")
    #expect(bot.importedSkills.first?.isEnabled == false)
    #expect(bot.routines.first?.isEnabled == false)
    let roundTrip = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
    #expect(roundTrip.importedSkills == bot.importedSkills)
    #expect(roundTrip.routines.first?.prompt == "")
}
