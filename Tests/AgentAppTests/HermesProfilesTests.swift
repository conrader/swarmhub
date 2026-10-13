import Foundation
import Testing
@testable import AgentApp

@MainActor private func profileStore(multiplex: Bool, served: Set<String> = [], keys: [String: String] = [:]) -> (AppStore, InMemoryKeyStore, UserDefaults, String) {
    let (host, session) = MockHermesProtocol.serve(hermesModelsHandler(multiplex: multiplex, served: served))
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let keyStore = InMemoryKeyStore(keys)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keyStore, defaults: defaults, hermesSession: session)
    return (store, keyStore, defaults, host)
}

@Test func profileSlugsBecomeReadableBotNames() {
    #expect(HermesProfileNaming.botName(forProfile: "grok-jarvis") == "Jarvis")
    #expect(HermesProfileNaming.botName(forProfile: "finance-controller") == "Finance Controller")
    #expect(HermesProfileNaming.botName(forProfile: "grok-admin") == "Admin")
    #expect(HermesProfileNaming.botName(forProfile: "cfo") == "Cfo")
    #expect(HermesProfileNaming.botName(forProfile: "grok-tax_office") == "Tax Office")
}

@Test func pastedProfileKeysParseLinesCommasWhitespaceAndEqualsInKeys() {
    let text = "  grok-jarvis = abc==  \n\n\r\ncfo=k=1=, finance-controller=xyz\n   \nnot-a-pair-secret123\ndefault=zz\nbad name=secret456\nempty=\ngrok-jarvis=newer"
    let parsed = HermesKeyPaste.parse(text)
    #expect(parsed.entries == [.init(profile: "cfo", key: "k=1="), .init(profile: "finance-controller", key: "xyz"), .init(profile: "grok-jarvis", key: "newer")])
    #expect(parsed.invalid.count == 4)
    #expect(parsed.invalid.map(\.label).contains("empty")); #expect(parsed.invalid.map(\.label).contains("default"))
    let rendered = parsed.invalid.map { $0.label + $0.reason }.joined()
    #expect(!rendered.contains("secret123")); #expect(!rendered.contains("secret456")); #expect(!rendered.contains("zz"))
    #expect(HermesKeyPaste.parse(" \n , \n").entries.isEmpty)
}

@Test func multiplexOffProfileIsRejectedByProbe() async {
    let (host, session) = MockHermesProtocol.serve(hermesModelsHandler(multiplex: false, served: []))
    let backend = HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "default-key", session: session)
    let probes = await backend.probeProfiles(named: ["grok-jarvis", "nokey"], keyFor: { $0 == "grok-jarvis" ? "jarvis-key" : "" })
    #expect(probes.map(\.id) == ["default", "grok-jarvis", "nokey"])
    #expect(probes[0].status == .available(.init(id: "default", name: "hermes-agent", model: "hermes-agent")))
    #expect(probes[1].status == .prefixIgnored)
    #expect(probes[1].status.reason == "Server ignored the profile prefix — enable gateway.multiplex_profiles")
    #expect(probes[2].status.reason?.contains("No API key") == true)
    #expect(try! await backend.discoverProfiles(named: ["grok-jarvis"], keyFor: { _ in "jarvis-key" }).map(\.id) == ["default"])
}

@Test @MainActor func discoveryNeverCreatesOrRoutesToPrefixIgnoredProfile() async throws {
    let (store, _, defaults, _) = profileStore(multiplex: false, keys: ["hermes.grok-jarvis": "jarvis-key"])
    defaults.set("grok-jarvis", forKey: "hermesProfiles")
    await store.refreshHermesAgents()
    #expect(!store.bots.contains { $0.hermesProfile == "grok-jarvis" })
    #expect(store.prefixIgnoredHermesProfiles == ["grok-jarvis"])
    let stale = Bot(name: "Stale", backend: .hermes, hermesProfile: "grok-jarvis")
    #expect(throws: BackendError.self) { try store.backend(for: stale) }
    #expect(store.hermesProfile(forTemplateSlug: "jarvis") == nil)
}

@Test @MainActor func discoveryNamesFromSlugsUsesProfileKeyAndIsIdempotent() async throws {
    let (store, _, defaults, host) = profileStore(multiplex: true, served: ["grok-jarvis", "finance-controller"], keys: ["hermes": "default-key", "hermes.grok-jarvis": "jarvis-key", "hermes.finance-controller": "fc-key"])
    defaults.set("grok-jarvis, finance-controller", forKey: "hermesProfiles")
    let mine = Bot(name: "Mine", backend: .mock); store.bots.append(mine)
    await store.refreshHermesAgents(); await store.refreshHermesAgents()
    let jarvis = try #require(store.bots.first { $0.hermesProfile == "grok-jarvis" })
    #expect(jarvis.name == "Jarvis")
    #expect(store.bots.first { $0.hermesProfile == "finance-controller" }?.name == "Finance Controller")
    #expect(store.bots.filter { $0.hermesProfile == "grok-jarvis" }.count == 1)
    #expect(store.bots.filter { $0.backend == .hermes && ($0.hermesProfile ?? "default") == "default" }.count == 1)
    #expect(store.bots.contains { $0.id == mine.id })
    let jarvisAuth = MockHermesProtocol.recorded(host).filter { $0.url?.path == "/p/grok-jarvis/v1/models" }.map { $0.value(forHTTPHeaderField: "Authorization") }
    #expect(!jarvisAuth.isEmpty); #expect(jarvisAuth.allSatisfy { $0 == "Bearer jarvis-key" })
}

@Test @MainActor func addBotsFromBoxStoresKeysProbesAndReportsPerProfile() async throws {
    let storeURL = temporaryStore()
    let (host, session) = MockHermesProtocol.serve(hermesModelsHandler(multiplex: true, served: ["grok-jarvis", "cfo"]))
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL"); defaults.set("cfo", forKey: "hermesProfiles")
    let keyStore = InMemoryKeyStore(["hermes.cfo": "cfo-old"])
    let store = AppStore(storeURL: storeURL, autoConfigureHermes: false, keyStore: keyStore, defaults: defaults, hermesSession: session)
    await store.refreshHermesAgents()
    let secrets = ["jarvis-SECRET==", "cfo-SECRET", "ghost-SECRET"]
    let results = await store.addBotsFromBox("grok-jarvis=\(secrets[0])\n cfo = \(secrets[1]) ,ghost=\(secrets[2])\njunk-without-equals")
    #expect(results.first { $0.label == "grok-jarvis" }?.outcome == .added("Jarvis"))
    #expect(results.first { $0.label == "cfo" }?.outcome == .alreadyPresent)
    guard case .rejected = results.first(where: { $0.label == "ghost" })?.outcome else { Issue.record("ghost must be rejected"); return }
    #expect(results.contains { $0.label == "Entry 4" })
    #expect(keyStore.key(for: "hermes.grok-jarvis") == secrets[0]); #expect(keyStore.key(for: "hermes.cfo") == secrets[1])
    #expect(store.namedHermesProfiles == ["cfo", "grok-jarvis", "ghost"])
    #expect(await store.addBotsFromBox("grok-jarvis=\(secrets[0])").first?.outcome == .alreadyPresent)
    #expect(store.bots.filter { $0.hermesProfile == "grok-jarvis" }.count == 1)
    let persisted = String(decoding: try Data(contentsOf: storeURL), as: UTF8.self)
    let defaultsDump = "\(defaults.dictionaryRepresentation())"
    let report = results.map(\.summary).joined() + (store.errorMessage ?? "")
    for secret in secrets { #expect(!persisted.contains(secret)); #expect(!defaultsDump.contains(secret)); #expect(!report.contains(secret)) }
}

@Test @MainActor func templateImportBindsToGrokProfileWhenKeyExists() throws {
    let (store, _, _, _) = profileStore(multiplex: true, keys: ["hermes.grok-garden": "garden-key", "hermes.planner": "planner-key"])
    let plan = store.makeImportPlan(from: try GrokTemplateParser.parse(#"{"name":"Garden","slug":"garden"}"#.data(using: .utf8)!))
    #expect(plan.hermesProfile == "grok-garden")
    let row = try #require(plan.report.first { $0.name == "Hermes profile" })
    #expect(row.status == .mapped); #expect(row.reason.contains("grok-garden")); #expect(!row.reason.contains("garden-key"))
    #expect(store.importTemplate(plan).hermesProfile == "grok-garden")
    let bare = store.makeImportPlan(from: try GrokTemplateParser.parse(#"{"name":"Planner","slug":"planner"}"#.data(using: .utf8)!))
    #expect(bare.hermesProfile == "planner")
}

@Test @MainActor func templateImportKeepsDefaultProfileWithoutMatchingKey() throws {
    let (store, _, _, _) = profileStore(multiplex: true, keys: ["hermes.grok-other": "other-key"])
    for json in [#"{"name":"Garden","slug":"garden"}"#, #"{"name":"No slug"}"#, #"{"name":"Odd","slug":"../x"}"#] {
        let plan = store.makeImportPlan(from: try GrokTemplateParser.parse(json.data(using: .utf8)!))
        #expect(plan.hermesProfile == nil)
        let row = try #require(plan.report.first { $0.name == "Hermes profile" })
        #expect(row.status == .converted); #expect(row.reason.contains("default Hermes profile"))
        #expect(store.importTemplate(plan).hermesProfile == "default")
    }
}
