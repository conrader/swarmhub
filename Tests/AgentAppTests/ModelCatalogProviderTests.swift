import Foundation
import Testing
@testable import AgentApp

// P17: an OpenClaw-shaped catalog through `ModelCatalogProviding` (a fake injected via `backendFactory`), and the
// real OpenClaw stub, which is never asked. Made-up names only; none may appear in `Sources/`.

let catalogProviderFixtureNames = ["drift-cloud", "Drift Cloud", "drift-a", "ember-labs", "ember-one", "quiet-host", "gw-default-x", "SECRET-GW-"]

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A gateway-shaped backend that only supplies a catalog: generic supplier names, a cooling-down supplier (a tag only),
/// a signed-out supplier and an agent default that is in no row.
struct FakeCatalogBackend: AgentBackend, ModelCatalogProviding {
    let kind = BackendKind.openClaw
    var catalogScope = "gw-1|quiet-host"
    var secrets = ["SECRET-GW-1"]
    var pinning = ModelCatalog.Pinning.none
    var failure: (@Sendable () -> Error)?
    let calls: CallCounter

    func modelCatalog(sessionID: String?) async throws -> ModelCatalog {
        calls.bump()
        if let failure { throw failure() }
        return ModelCatalog(suppliers: [
            .init(slug: "drift-cloud", name: "Drift Cloud", tags: ["cooling down"], models: ["drift-a", "drift-b"]),
            .init(slug: "ember-labs", name: ModelCatalog.Supplier.titleCased("ember-labs"), models: ["ember-one"], blockedReason: "signed out on the gateway", needsSignIn: true),
        ], defaultSupplier: "drift-cloud", agentDefault: .init(model: "gw-default-x", supplier: "drift-cloud"), pinning: pinning,
           place: "the OpenClaw gateway", detail: "Agent quiet-host")
    }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> { throw BackendError.unavailable("fake") }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .disconnectedLegacy }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "fake" }
}

@MainActor private func clawStore(_ backend: FakeCatalogBackend) -> (AppStore, Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let claw = Bot(name: "Claw", backend: .openClaw); store.bots = [claw]
    return (store, claw)
}

@MainActor private func editor(_ store: AppStore, _ bot: Bot?, pending: BackendKind? = nil, setting: ModelSetting = .inherit) -> RoleModelEditorModel {
    RoleModelEditorModel(isNew: bot == nil, savedBackend: bot?.backend, pendingBackend: pending ?? bot?.backend ?? .hermes,
                         catalog: bot.map { store.modelCatalog(for: $0) } ?? .loading, hasEntry: bot.flatMap { store.botInfo.info(for: $0.id) } != nil,
                         autoLoad: store.botInfo.autoLoad, appDefault: store.modelDefaults.conversation, setting: setting)
}

@Test(arguments: [ModelCatalog.Pinning.reversible, .none]) @MainActor func gatewayCatalogsRenderReadOnlyEverywhere(pinning: ModelCatalog.Pinning) async {
    let calls = CallCounter()
    let (store, claw) = clawStore(FakeCatalogBackend(pinning: pinning, calls: calls))
    #expect(store.modelPicker(for: claw).showsMenu == false && calls.value == 0, "nothing is read before a load")
    await store.loadServerInfo(for: claw)
    await store.loadServerInfo(for: claw)
    #expect(calls.value == 1, "the same entry and staleness as Hermes")

    let picker = store.modelPicker(for: claw)
    #expect(picker.showsMenu && picker.groups.map(\.title) == ["Drift Cloud · default · cooling down", "Ember Labs"])
    #expect(picker.groups.flatMap(\.items).allSatisfy { !$0.isEnabled } && !picker.canSwitch, "no enabled apply control")
    #expect(picker.groups[1].items[0].disabledReason == "signed out on the gateway")
    #expect(picker.unpinHelp == nil && !picker.notes.contains { $0.text.contains("unpin") })
    #expect(picker.notes.map(\.text).contains(ModelCatalog.switchingLater))
    #expect(picker.caption == "Models provided by 2 providers on the OpenClaw gateway · default Drift Cloud")
    #expect(picker.footer?.hasPrefix("Agent quiet-host") == true)
    #expect(store.currentModel(for: claw) == .init(model: "gw-default-x", provider: "drift-cloud", source: "agent default"))

    let model = editor(store, claw)
    #expect(model.showsMenu && !model.canChoose && !model.showsUnpinCopy && model.reason == ModelCatalog.switchingLater)
    #expect(model.leading.map(\.title) == ["Agent default (gw-default-x)"])

    let row = store.modelRolesRow(for: claw)
    #expect(row.canAsk && row.readOnly == ModelCatalog.switchingLater && row.blocked == nil && row.server == "OpenClaw")
    #expect(row.conversation?.text == "Conversation: gw-default-x · Drift Cloud · agent default")
    #expect(store.editorModelsSummary(for: claw) == "Claw: editor models the OpenClaw gateway, Agent quiet-host; agent default gw-default-x; \(AppConstants.name) default none; 2 suppliers")

    store.modelDefaults.conversation = ModelChoice(provider: "drift-cloud", model: "drift-a")
    #expect(store.editorModelsSummary(for: claw).contains("\(AppConstants.name) default offered"))
    #expect(store.modelRoles().offerSummary(store.modelDefaults.conversation) == "Offered by 1 of 1 agents")
    #expect(editor(store, claw).leading.first?.title == "\(AppConstants.name) default (drift-a)")
}

@Test @MainActor func theRealOpenClawStubSaysWhyWithZeroRequests() async {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let claw = Bot(name: "Claw", backend: .openClaw), mock = Bot(name: "Mocky", backend: .mock)
    let archive = Bot(name: "Old", backend: .hermes, hermesProfile: "grok-old"); archive.archivedMembers = ["A"]
    let history = Bot(name: "Past", backend: .hermes); history.grokSourceID = "grok-src-1"
    store.bots = [claw, mock, archive, history]
    await store.loadModelRoles()
    for bot in store.bots { await store.loadServerInfo(for: bot); await store.loadEditorModels(for: bot, pendingBackend: bot.backend) }
    #expect(store.botInfo.info(for: claw.id) == nil && store.botInfo.info(for: mock.id) == nil && store.botInfo.info(for: archive.id) == nil)
    let expected: [(Bot, String)] = [(claw, "Models come from the OpenClaw gateway once connected."), (mock, "This agent has no model backend."),
                                     (archive, "This agent is a read-only archive."), (history, "History only — not connected to a Hermes profile yet.")]
    for (bot, text) in expected {
        #expect(store.modelCatalog(for: bot) == .unavailable(text), "\(bot.name)")
        #expect(store.modelPicker(for: bot).notes.map(\.text) == [text])
        #expect(editor(store, bot).reason == text && !editor(store, bot).showsMenu)
        #expect(store.editorModelsSummary(for: bot) == "\(bot.name): editor models no list (\(text))")
    }
}

@Test @MainActor func gatewayErrorsAreMappedAndRedacted() async {
    let cases: [(Error, Loadable<ModelCatalog>)] = [
        (BackendError.http(500, "upstream SECRET-GW-1 down"), .failed("HTTP 500: upstream [key] down")),
        (BackendError.http(404, "no method"), .unavailable("This agent's backend does not list its models.")),
        (BackendError.unavailable("Update OpenClaw to list this agent's models."), .unavailable("Update OpenClaw to list this agent's models.")),
    ]
    for (error, expected) in cases {
        let (store, claw) = clawStore(FakeCatalogBackend(failure: { error }, calls: CallCounter()))
        await store.loadServerInfo(for: claw)
        let catalog = store.modelCatalog(for: claw)
        if case .failed(let text) = expected { #expect(catalog == .failed(BotInfoCache.describe(error, secrets: ["SECRET-GW-1"])) && !text.contains("SECRET")) }
        else { #expect(catalog == expected) }
        #expect(!String(reflecting: catalog).contains("SECRET-GW-1"))
        #expect(editor(store, claw).offersRetry == (catalog.value == nil && { if case .failed = catalog { true } else { false } }()))
    }
}
