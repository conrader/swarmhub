import Foundation
import Testing
@testable import AgentApp

// The Grok import's hardened secret filter (ported from AgentApp). These tests use only APIs that predate the port, so
// they also run against the old filter, where each fails: case variants, wider AWS ids and encoded secrets walked
// past it, an imported persona went to the backend unfiltered, and the template filter rescanned per match.

/// Credential shapes the old, case-sensitive filter let through; all synthetic.
private let variants = [
    "akia1234567890abcdef", "ASIAABCDEFGHIJKLMNOP", "GITHUB_PAT_syntheticMarker1234567890",
    "EyJsyntheticheader.syntheticpayload.syntheticsign", "aizaabcdefghijklmnopqrstuvwxyz123456789",
    "XAPP-syntheticMarker123456", "HTTPS://HOOKS.SLACK.COM/services/SYNTHETIC/MARKER", "SK-syntheticMarker12345",
    "syntheticUser%3AsyntheticPass", "c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz", "-----begin rsa private key-----",
]
private let prose = """
The volunteer rota is published every Monday and the authorised contacts list lives in the shared binder. Please use \
basic judgement, keep the password-protected door closed, and token gestures of thanks are welcome at the harvest supper. \
Use basic troubleshooting before escalation; see /usr/local/lib/python3.12/site-packages for internationalization, 100% sure.
"""

@Test func grokImportRedactsCasingAndEncodingVariants() {
    let inputs = [
        "akia1234567890abcdef", "ASIAABCDEFGHIJKLMNOP", "GITHUB_PAT_syntheticMarker1234567890",
        "Mixed-case JWT EyJsyntheticheader.syntheticpayload.syntheticsign in prose.",
        "The key aizaabcdefghijklmnopqrstuvwxyz123456789 must never survive.",
        "App token XAPP-syntheticMarker123456 and hook HTTPS://HOOKS.SLACK.COM/services/SYNTHETIC/MARKER.",
        "SK-syntheticMarker12345", "Mirror https://syntheticUser%3AsyntheticPass@example.invalid/feed each week.",
        "key c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz end", "-----begin rsa private key-----\nabc\n-----end rsa private key-----\n",
    ]
    var redact = GrokRedactor()
    let output = inputs.map { redact($0) }.joined(separator: "\n")
    for marker in variants { #expect(!output.contains(marker), "\(marker)") }
    #expect(output.contains("Mixed-case JWT [REDACTED] in prose."))
    #expect(output.contains("Mirror [REDACTED] each week."))
    #expect(output.contains("key [REDACTED] end"))
    #expect(redact.counts == ["aws_key": 2, "github_pat": 1, "jwt": 1, "google_key": 1, "slack_app_token": 1, "slack_webhook": 1,
                              "vendor_token": 1, "encoded_credential": 2, "private_key": 1])
    var quiet = GrokRedactor()
    #expect(quiet(prose) == prose)
    #expect(quiet.total == 0)
}

@Test @MainActor func templateImportRedactsCasingAndEncodingVariantsBeforeStorage() throws {
    for secret in variants {
        let object: [String: Any] = [
            "name": "Safe", "persona": "Persona before \(secret) persona after",
            "memories": [["name": "Safe memory", "value": "Memory before \(secret) memory after"]],
        ]
        let manifest = try GrokTemplateParser.parse(JSONSerialization.data(withJSONObject: object))
        #expect(manifest.rejectedSecretCount == 2, "\(secret)")
        #expect(!manifest.instructions.contains(secret) && manifest.instructions.hasPrefix("Persona before "), "\(secret)")
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = []
        _ = store.importTemplate(TemplateImportMapper.makePlan(from: manifest))
        #expect(!String(decoding: try JSONEncoder().encode(store.bots), as: UTF8.self).contains(secret), "\(secret)")
    }
    let kept = try GrokTemplateParser.parse(JSONSerialization.data(withJSONObject: ["name": "Safe", "persona": prose]))
    #expect(kept.instructions == prose.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(kept.rejectedSecretCount == 0)
}

@Test @MainActor func anImportedPersonaIsFilteredBeforeItBecomesTheSystemPrompt() async throws {
    // A persona imported before this filter (or by an older one) still holds the credential; a typed one is the owner's.
    // The import binds a chatting bot to a profile; without one it is history-only and Send refuses it.
    let imported = Bot(name: "Imported", persona: "Keep it brief. Use Bearer syntheticPersonaToken123 and akia1234567890abcdef.",
                       backend: .hermes, hermesProfile: "grok-imported", hermesSessionID: "imported-chat")
    imported.grokSourceID = "00000000-0000-4000-8000-0000000000aa"
    let typed = Bot(name: "Typed", persona: "Keep it brief. token: hand-typed-value", backend: .hermes, hermesSessionID: "typed-chat")
    let cases: [(Bot, [String], String)] = [
        (imported, ["syntheticPersonaToken123", "akia1234567890abcdef"], "Keep it brief. Use [REDACTED] and [REDACTED]."),
        (typed, [], "Keep it brief. token: hand-typed-value"),
    ]
    for (bot, expectGone, expectKept) in cases {
        let backend = AppRequestBackend(.normal)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = [bot]; store.selectedBot = bot
        try #require(store.submitComposer(text: "Hello"), "\(bot.name)")
        try await waitUntil { !(await backend.recorded().isEmpty) }  // The suite's ceiling: 30 s timed out under load.
        let prompt = try #require(await backend.recorded().first?.systemPrompt)
        for secret in expectGone { #expect(!prompt.contains(secret), "\(bot.name)") }
        #expect(prompt.contains(expectKept), "\(bot.name)")
        #expect(bot.persona.contains(expectGone.first ?? "token: hand-typed-value"), "the stored persona is not rewritten")
    }
}

@Test @MainActor func craftedSecretDenseTextRedactsInLinearTime() throws {
    // AgentApp's MEDIUM: rescanning after each replacement made dense input quadratic. `-eyJ…` chains and a long token
    // with a stray `%` are the two shapes that also made single patterns rescan to the end from every offset.
    let clock = ContinuousClock()
    let dense = String(repeating: "token=abcdefgh ", count: 10_000)
    let crafted = [dense, String(repeating: "-eyJxxxxxxxx", count: 20_000), String(repeating: "a%zz", count: 150_000) + " %41"]
    for (index, text) in crafted.enumerated() {
        var redact = GrokRedactor()
        var output = ""
        let elapsed = clock.measure { output = redact(text) }
        #expect(elapsed < .seconds(2), "input \(index): \(elapsed)")
        #expect(index != 0 || (redact.counts == ["credential_assignment": 10_000] && !output.contains("abcdefgh")))
        #expect(index == 0 || output == text)
    }
    let json = try JSONSerialization.data(withJSONObject: ["name": "Dense", "persona": dense])
    var manifest: ImportedTemplateManifest?
    let parsed = try clock.measure { manifest = try GrokTemplateParser.parse(json) }
    #expect(parsed < .seconds(2), "template parse: \(parsed)")
    #expect(manifest?.rejectedSecretCount == 10_000)
}
