import Foundation
import Testing
@testable import AgentApp

// P25: OpenClaw in the setup window, over the fake Gateway (loopback address, scripted transport, no network).

/// An in-memory key store that records every write and delete (a blank value is a delete).
final class RecordingKeyStore: HermesKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String] = [:]
    private(set) var writes: [String] = [], deletes: [String] = []
    func key(for account: String) -> String { lock.withLock { values[account] ?? "" } }
    func setKey(_ value: String, for account: String) {
        lock.withLock {
            if value.isEmpty { if values.removeValue(forKey: account) != nil { deletes.append(account) } } else { values[account] = value; writes.append(account) }
        }
    }
    var accounts: Set<String> { lock.withLock { Set(values.keys) } }
    var log: (writes: [String], deletes: [String]) { lock.withLock { (writes, deletes) } }
}

@MainActor private func setupStore(_ fake: FakeGateway = FakeGateway(), keys: RecordingKeyStore = RecordingKeyStore(), defaults: UserDefaults = isolatedDefaults()) -> AppStore {
    let hub = OpenClawHub(status: OpenClawStatus(), keyStore: keys, makeTransport: fake.factory, clock: SystemGatewayClock(), jitter: { 0 })
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults, openClawHub: hub)
    store.loadOpenClawGateways()
    return store
}

private func draft(key: String = fakeSharedToken) -> OpenClawDraft { var draft = OpenClawDraft(); draft.key = key; return draft }

private func threeAgents() -> FakeGateway.Handler {
    { _, _ in .success(["defaultId": "agent-alpha", "mainKey": "main",
                        "agents": [["id": "agent-alpha", "identity": ["name": "Alpha"]], ["id": "agent-beta", "name": "Beta"], ["id": "agent-gamma", "name": "Gamma"]]]) }
}

@Test func theTransitionTableOffersTheSoftwareChoice() {
    #expect(OpenClawBackend.isImplemented && SetupFlow.offersSoftwareChoice)
    #expect(SetupFlow.Step.allCases == [.welcome, .hosting, .software, .address, .openClaw, .choose, .done])
    var flow = SetupFlow()
    flow.apply(.connectExisting); #expect(flow.step == .software && flow.canGoBack && !flow.canSkip)
    flow.apply(.pick(.hermes)); #expect(flow.step == .address && flow.software == .hermes)
    flow.apply(.back); #expect(flow.step == .software)
    flow.apply(.pick(.openClaw)); #expect(flow.step == .openClaw && flow.software == .openClaw && flow.canGoBack)
    flow.apply(.openClawTest(.failed("Can’t reach the Gateway."), gatewayID: "gw")); #expect(flow.step == .openClaw && flow.openClawFailure != nil)
    flow.apply(.openClawTest(.pairingRequired(requestId: "req-1"), gatewayID: "gw")); #expect(flow.step == .openClaw && flow.awaitsPairing)
    flow.apply(.openClawTest(.connected([.init(id: "a", name: "A")]), gatewayID: "gw")); #expect(flow.step == .choose && flow.choices == [.init(id: "a", name: "A")])
    flow.apply(.back); #expect(flow.step == .openClaw && flow.openClawGatewayID == "gw", "Back from choose keeps the tested Gateway")
    flow.apply(.back); #expect(flow.step == .software && flow.openClawGatewayID == nil && flow.openClawOutcome == nil, "Back to the choice undoes the Test")
    flow.apply(.back); #expect(flow.step == .welcome && !flow.canGoBack)
    // The hosting card's footer button goes to the software choice too.
    var hosting = SetupFlow(); hosting.apply(.newHosted); hosting.apply(.connectExisting)
    #expect(hosting.step == .software)
    hosting.apply(.back); #expect(hosting.step == .hosting)
    // Change connection / the history-only banner start on the (Hermes) address step, with Back to the software choice.
    var change = SetupFlow(prefill: .init(address: "https://old.example.com", startAtAddress: true))
    #expect(change.step == .address && change.software == .hermes && change.canGoBack)
    change.apply(.back); #expect(change.step == .software)
    change.apply(.back); #expect(change.step == .welcome)
    // Add ends on Done, from which nothing goes back.
    var done = SetupFlow(); done.apply(.connectExisting); done.apply(.pick(.openClaw))
    done.apply(.openClawTest(.connected([.init(id: "a")]), gatewayID: "gw")); done.preselect(alreadyAdded: [])
    #expect(done.chosen == ["a"] && done.canAdd && !done.movesAddress)
    done.apply(.add(count: 1, first: "a")); #expect(done.step == .done && !done.canGoBack)
    done.apply(.back); #expect(done.step == .done)
}

@Test func theConnectScreenValidatesTheAddressInline() {
    var draft = OpenClawDraft()
    #expect(draft.url == OpenClawCopy.tunnelURL && draft.problem == nil && draft.deviceName == OpenClawGateway.defaultDeviceName && !draft.keepsKey)
    draft.url = "ws://claw.example.com:18789"
    #expect(draft.problem == GatewayURLRules.Problem.plaintextPublic.errorDescription && draft.gateway(updating: nil) == nil)
    draft.url = "ws://192.168.1.20"; #expect(draft.problem == GatewayURLRules.Problem.plaintextPrivate.errorDescription)
    draft.allowPrivatePlaintext = true; #expect(draft.problem == nil && draft.gateway(updating: nil)?.url == "ws://192.168.1.20:18789")
    draft.key = "   "; #expect(draft.typedKey == nil, "a blank key means Tailscale or proxy identity")
}

@MainActor @Test func testConnectsAndChooseListsTheGatewaysAgents() async throws {
    let fake = FakeGateway(); fake.handlers["agents.list"] = threeAgents()
    let store = setupStore(fake)
    let tested = await store.testSetupGateway(draft())
    let id = try #require(tested.gatewayID)
    guard case .connected(let agents) = tested.outcome else { Issue.record("not connected: \(tested.outcome)"); return }
    #expect(agents.map(\.id) == ["agent-alpha", "agent-beta", "agent-gamma"] && store.setupCreatedGatewayID == id)
    #expect(store.openClawGateways.map(\.id) == [id] && store.openClawGateways.first?.url == "ws://127.0.0.1:18789")
    // One agent already has a bot on this Gateway: shown, ticked and disabled; the others start ticked.
    let bound = Bot(name: "Alpha", backend: .openClaw); bound.openClaw = .init(gatewayID: id, agentID: "agent-alpha"); store.bots.append(bound)
    var flow = SetupFlow(); flow.apply(.connectExisting); flow.apply(.pick(.openClaw))
    flow.apply(.openClawTest(tested.outcome, gatewayID: id)); flow.preselect(alreadyAdded: store.openClawAgentIDs(boundTo: id))
    #expect(flow.step == .choose && flow.choices.map(\.name) == ["Alpha", "Beta", "Gamma"])
    #expect(store.openClawAgentIDs(boundTo: id) == ["agent-alpha"] && flow.chosen == ["agent-beta", "agent-gamma"])
}

@MainActor @Test func pairingRequiredShowsTheApproveCommandThenTestAgainConnects() async throws {
    let fake = FakeGateway(); fake.requiresApproval = true
    let store = setupStore(fake)
    let first = await store.testSetupGateway(draft())
    #expect(first.outcome == .pairingRequired(requestId: "req-1"))
    var flow = SetupFlow(); flow.apply(.connectExisting); flow.apply(.pick(.openClaw))
    flow.apply(.openClawTest(first.outcome, gatewayID: first.gatewayID))
    #expect(flow.step == .openClaw && flow.awaitsPairing && GatewayState.approveCommand(flow.pairingRequestId) == "openclaw devices approve req-1")
    #expect(GatewayState.approveCommand("req-1; rm -rf ~") == "openclaw devices approve <requestId>", "an unsafe id never reaches the command")
    fake.approve()
    let again = await store.testSetupGateway(draft(key: ""))
    #expect(again.gatewayID == first.gatewayID, "Test again reuses this run's Gateway")
    guard case .connected(let agents) = again.outcome else { Issue.record("not connected after approval: \(again.outcome)"); return }
    #expect(agents.map(\.id) == ["agent-alpha", "agent-beta"])
    flow.apply(.openClawTest(again.outcome, gatewayID: again.gatewayID)); #expect(flow.step == .choose)
}

@MainActor @Test func aFailedTestShowsOneRedactedLineWithoutTheKey() async {
    let fake = FakeGateway(); fake.sharedToken = "the-real-token"
    let store = setupStore(fake)
    let tested = await store.testSetupGateway(draft(key: "wrong-secret-value"))
    guard case .failed(let line) = tested.outcome else { Issue.record("expected a failure: \(tested.outcome)"); return }
    #expect(line == GatewayFailure.tokenRejected.line && !line.contains("wrong-secret-value") && !line.contains("the-real-token"))
}

@MainActor @Test func cancelBackOrCloseForgetsOnlyTheGatewayThisRunCreated() async throws {
    // Cancel, Back to the software choice and closing the window all call `abandonSetupGateway`.
    for _ in 0..<3 {
        let keys = RecordingKeyStore(), store = setupStore(keys: keys)
        let tested = await store.testSetupGateway(draft())
        let id = try #require(tested.gatewayID)
        let gateway = try #require(store.gateway(id: id))
        #expect(keys.accounts.contains(gateway.deviceKeyAccount) && keys.accounts.contains(gateway.deviceTokenAccount), "Test saved the identity and pairing")
        await store.abandonSetupGateway()
        #expect(store.openClawGateways.isEmpty && GatewayStore(defaults: store.defaults, keyStore: keys).load().isEmpty && store.setupCreatedGatewayID == nil)
        #expect(keys.accounts.isEmpty && Set(keys.log.deletes).isSuperset(of: [gateway.deviceKeyAccount, gateway.deviceTokenAccount]), "its Keychain items are deleted")
        await store.abandonSetupGateway() // a second call (e.g. Cancel, then the window closing) is a no-op
    }
    // A Gateway saved before this run, at the same address, is used but never forgotten.
    let keys = RecordingKeyStore(), defaults = isolatedDefaults()
    let (existing, _) = fakeGatewaySetup()
    GatewayStore(defaults: defaults, keyStore: keys).upsert(existing); keys.setKey(fakeSharedToken, for: existing.tokenAccount)
    let store = setupStore(keys: keys, defaults: defaults)
    let tested = await store.testSetupGateway(draft(key: ""))
    #expect(tested.gatewayID == existing.id && store.setupCreatedGatewayID == nil)
    let before = keys.accounts, deletesBefore = keys.log.deletes
    await store.abandonSetupGateway()
    #expect(store.openClawGateways == [existing] && keys.accounts == before && keys.log.deletes == deletesBefore, "the pre-existing Gateway is untouched")
}

@MainActor @Test func aNewAddressStartsAFreshGatewaySoTheOldKeyIsNeverSentThere() async throws {
    let keys = RecordingKeyStore(), store = setupStore(keys: keys)
    var typed = draft(); typed.keepsKey = true
    let first = await store.testSetupGateway(typed)
    let old = try #require(store.gateway(id: first.gatewayID))
    #expect(keys.key(for: old.tokenAccount) == fakeSharedToken)
    var moved = draft(key: ""); moved.url = "ws://localhost:18790"
    let second = await store.testSetupGateway(moved)
    let fresh = try #require(store.gateway(id: second.gatewayID))
    #expect(fresh.id != old.id && store.openClawGateways == [fresh] && store.setupCreatedGatewayID == fresh.id)
    #expect(keys.key(for: fresh.tokenAccount).isEmpty && !keys.accounts.contains(old.tokenAccount), "the old key went with the old Gateway")
    await store.abandonSetupGateway()
}

@MainActor @Test func addCreatesOneBotPerTickedAgentAndIsIdempotent() async throws {
    let fake = FakeGateway(); fake.handlers["agents.list"] = threeAgents()
    let store = setupStore(fake)
    store.loadSamples()
    let tested = await store.testSetupGateway(draft())
    guard case .connected(let agents) = tested.outcome else { Issue.record("not connected"); return }
    let added = try store.commitSetupOpenClaw(gatewayID: tested.gatewayID, agents: agents, chosen: ["agent-alpha", "agent-gamma"])
    let claws = store.bots.filter { $0.backend == .openClaw }
    #expect(added.count == 2 && claws.count == 2 && claws.allSatisfy { $0.openClaw?.gatewayID == tested.gatewayID && $0.title == "OpenClaw agent" })
    #expect(Set(claws.compactMap { $0.openClaw?.agentID }) == ["agent-alpha", "agent-gamma"] && !claws.contains { $0.joinsGroups })
    #expect(store.selectedBot === added.first && FirstRun.state(store.defaults) == .done && store.bots.filter(\.isDemo).allSatisfy(\.isHidden))
    #expect(store.setupCreatedGatewayID == nil, "Add keeps the Gateway")
    await store.abandonSetupGateway(); #expect(store.openClawGateways.count == 1, "closing the window after Add forgets nothing")
    let again = try store.commitSetupOpenClaw(gatewayID: tested.gatewayID, agents: agents, chosen: ["agent-alpha", "agent-gamma"])
    #expect(again.isEmpty && store.bots.filter { $0.backend == .openClaw }.count == 2)
    #expect(throws: AppStore.SetupCommitError.nothingChosen) { try store.commitSetupOpenClaw(gatewayID: tested.gatewayID, agents: agents, chosen: []) }
    #expect(throws: AppStore.SetupCommitError.notTested) { try store.commitSetupOpenClaw(gatewayID: nil, agents: agents, chosen: ["agent-beta"]) }
    // Settings' "Add bots" (nil = all) goes through the same function: only the unticked agent is new.
    let gateway = try #require(store.gateway(id: tested.gatewayID))
    let settings = try await store.addBotsFromGateway(gateway)
    #expect(settings.filter(\.added).map(\.name) == ["Beta"] && store.bots.filter { $0.backend == .openClaw }.count == 3)
}

@MainActor @Test func theOpenClawScreensRenderWithoutConnecting() async {
    let fake = FakeGateway(), store = setupStore(fake)
    var flow = SetupFlow(); flow.apply(.connectExisting)
    var pairing = flow; pairing.apply(.pick(.openClaw)); pairing.apply(.openClawTest(.pairingRequired(requestId: "req-9"), gatewayID: nil))
    for state in [flow, pairing] {
        let png = await SnapshotRenderer.png(SetupView(preset: state).environmentObject(store).defaultAppStorage(store.defaults), size: HeadlessSetup.size)
        #expect(png != nil)
    }
    #expect(fake.connectParams.isEmpty && store.openClawGateways.isEmpty, "showing S2 and S3-OC saves and connects nothing")
}
