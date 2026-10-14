import Foundation
import Testing
@testable import AgentApp

// P21 items 13-14: the setup window's in-memory Test against a synthetic box, and the one atomic commit.

private let goodKey = "synthetic-main-key", researchKey = "synthetic-research", writerKey = "synthetic-writer"

/// A synthetic box: health, then `/v1/models` per agent, each agent accepting only its own key.
private func box(multiplex: Bool = true, status: Int? = nil) -> (address: String, session: URLSession, host: String) {
    let keys = ["default": goodKey, "research": researchKey, "writer": writerKey]
    let (host, session) = MockHermesProtocol.serve { request in
        let path = request.url!.path
        if path == "/health/detailed" { return (200, ["version": "0.21.7", "status": "ok"]) }
        let parts = path.split(separator: "/").map(String.init)
        let profile = parts.count == 4 && parts[0] == "p" ? parts[1] : "default"
        guard parts.suffix(2) == ["v1", "models"] else { return (404, ["error": "no route"]) }
        if let status { return (status, ["error": "synthetic"]) }
        let target = multiplex ? profile : "default"
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(keys[target] ?? "")" || !multiplex && profile != "default" else { return (401, ["error": "bad key"]) }
        return (200, ["data": [["id": multiplex && profile != "default" ? profile : "hermes-agent"]]])
    }
    return ("https://\(host)", session, host)
}

private func run(_ input: SetupInput, _ server: (address: String, session: URLSession, host: String)) async -> SetupCheckResult {
    await SetupCheck.run(input, session: server.session)
}

@Test func addressesAreNormalised() {
    #expect(BoxAddress.normalize("  my-box.example.com/ ") == "https://my-box.example.com")
    #expect(BoxAddress.normalize("http://127.0.0.1:8642/v1/") == "http://127.0.0.1:8642/v1")
    #expect(BoxAddress.url("not an address") == nil && BoxAddress.url("") == nil)
    #expect(BoxAddress.place(URL(string: "http://localhost:8642")!) == "this Mac" && BoxAddress.place(URL(string: "https://my-box.example.com")!) == "my-box.example.com")
}

@Test func eachOutcomeReadsPlainly() async {
    let server = box()
    let mainOnly = await run(.init(address: server.address, key: goodKey), server)
    #expect(mainOnly.outcome == .connected(place: server.host, count: 1) && mainOnly.message == "Connected to \(server.host). Found 1 agent.")
    let three = await run(.init(address: server.address, key: goodKey, extra: "research=\(researchKey)\nwriter=\(writerKey)"), server)
    #expect(three.outcome == .connected(place: server.host, count: 3) && three.available.map(\.name) == ["hermes-agent", "Research", "Writer"])
    #expect(three.extraKeys == ["research": researchKey, "writer": writerKey])

    let wrong = await run(.init(address: server.address, key: "wrong-key"), server)
    #expect(wrong.outcome == .keyRejected && wrong.message == SetupCopy.keyRejected && wrong.probes.first?.httpStatus == 401)
    let forbidden = box(status: 403)
    #expect(await run(.init(address: forbidden.address, key: goodKey), forbidden).outcome == .keyRejected)

    let unreachable = await SetupCheck.run(.init(address: "https://unreachable.invalid", key: goodKey), session: UnreachableProtocol.session)
    #expect(unreachable.outcome == .unreachable && unreachable.message.hasPrefix("Could not reach that address"))

    let lan = await SetupCheck.run(.init(address: "http://192.168.1.5:8642", key: goodKey), session: UnreachableProtocol.session)
    #expect(lan.outcome == .notEncrypted(port: 8642))
    #expect(lan.message.contains("https://") && lan.message.contains("tunnel") && lan.message.contains("http://localhost:8642"))
    #expect(await SetupCheck.run(.init(address: "::::", key: goodKey)).outcome == .badAddress)
    #expect(await run(.init(address: server.address, key: goodKey, extra: "no equals sign"), server).outcome == .badLine)

    let off = box(multiplex: false)
    let ignored = await run(.init(address: off.address, key: goodKey, extra: "research=\(researchKey)"), off)
    #expect(ignored.outcome == .connected(place: off.host, count: 1) && ignored.problems == [SetupCopy.mainOnly("Research")])
    let failing = box(status: 500)
    let onlyIgnored = SetupCheckResult(outcome: .noAgents, probes: [.init(id: "research", status: .prefixIgnored)])
    #expect(await run(.init(address: failing.address, key: goodKey), failing).outcome == .noAgents && onlyIgnored.problems == [SetupCopy.mainOnly("Research")])
    #expect(SetupCheck.message(.mainOnly("Research")) == "This box only serves its main agent, so Research cannot be added.")

    for result in [mainOnly, three, wrong, unreachable, lan, ignored] {
        for key in [goodKey, researchKey, writerKey, "wrong-key"] {
            #expect(!result.message.contains(key) && !result.problems.joined().contains(key), "a key never appears in a message")
        }
    }
}

@MainActor private func setupStore(url: URL = temporaryStore(), keys: InMemoryKeyStore = InMemoryKeyStore(), defaults: UserDefaults = isolatedDefaults()) -> AppStore {
    AppStore(storeURL: url, autoConfigureHermes: false, keyStore: keys, defaults: defaults)
}

private func snapshot(_ defaults: UserDefaults) -> [String: String] {
    Dictionary(uniqueKeysWithValues: ["hermesBaseURL", "hermesProfiles", FirstRun.stateKey].map { ($0, defaults.string(forKey: $0) ?? "-") })
}

@MainActor @Test func aFailedTestAndCancelChangeNothing() async throws {
    let keys = InMemoryKeyStore(), defaults = isolatedDefaults(), store = setupStore(keys: keys, defaults: defaults)
    store.bots = [Bot(name: "Kept", backend: .hermes, hermesProfile: "kept")]; store.save()
    let file = try Data(contentsOf: store.fileURL), settings = snapshot(defaults)
    let server = box()
    _ = await run(.init(address: server.address, key: "wrong-key", extra: "research=\(researchKey)"), server)
    _ = await run(.init(address: server.address, key: goodKey, extra: "research=\(researchKey)"), server)
    let afterTest = try Data(contentsOf: store.fileURL)
    #expect(keys.all().isEmpty && snapshot(defaults) == settings && afterTest == file, "Test writes nothing")
    FirstRun.dismissed(defaults)
    let afterCancel = try Data(contentsOf: store.fileURL)
    #expect(keys.all().isEmpty && afterCancel == file && store.bots.map(\.name) == ["Kept"])
    #expect(FirstRun.state(defaults) == .skipped && defaults.string(forKey: "hermesBaseURL") == nil, "Cancel only records that the window was dismissed")
}

@MainActor @Test func addWritesExactlyTheTickedAgentsAtOnceAndIsIdempotent() async throws {
    let keys = InMemoryKeyStore(), defaults = isolatedDefaults(), store = setupStore(keys: keys, defaults: defaults)
    store.loadSamples()
    #expect(store.bots.allSatisfy(\.isDemo) && store.bots.allSatisfy { !$0.isHidden })
    let server = box()
    let result = await run(.init(address: server.address, key: goodKey, extra: "research=\(researchKey)\nwriter=\(writerKey)"), server)
    let requests = MockHermesProtocol.recorded(server.host).count
    let added = try store.commitSetup(result, key: goodKey, chosen: ["default", "research"], confirmMove: false)
    #expect(MockHermesProtocol.recorded(server.host).count == requests, "Add makes no second network call")
    #expect(added.map(\.hermesProfile) == ["default", "research"] && added.map(\.name) == ["hermes-agent", "Research"])
    #expect(keys.all() == ["hermes": goodKey, "hermes.research": researchKey], "the unticked agent's key is not saved")
    #expect(defaults.string(forKey: "hermesBaseURL") == server.address && store.namedHermesProfiles == ["research"])
    #expect(FirstRun.state(defaults) == .done && store.selectedBot === added[0])
    #expect(store.bots.filter(\.isDemo).allSatisfy(\.isHidden) && store.hiddenChatBots.isEmpty, "sample bots are hidden at once and not listed")
    let saved = try StoreFile.decode(Data(contentsOf: store.fileURL))
    #expect(saved.bots.filter { !$0.isDemo }.map(\.name) == ["hermes-agent", "Research"])
    let again = try store.commitSetup(result, key: "", chosen: ["default", "research"], confirmMove: false)
    #expect(again.isEmpty && store.bots.filter { !$0.isDemo }.count == 2 && keys.all()["hermes"] == goodKey, "twice adds nothing; an empty key keeps the saved one")
}

@MainActor @Test func aFailedSaveRollsEverythingBack() async throws {
    let blocker = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-\(UUID().uuidString)")
    try Data("not a folder".utf8).write(to: blocker)
    let keys = InMemoryKeyStore(["hermes": "old-key"]), defaults = isolatedDefaults()
    defaults.set("https://old.example.com", forKey: "hermesBaseURL")
    let store = setupStore(url: blocker.appending(path: "store.json"), keys: keys, defaults: defaults)
    let existing = Bot(name: "Existing", backend: .hermes, hermesProfile: "default"); store.bots = [existing]
    let server = box()
    let result = await run(.init(address: server.address, key: goodKey, extra: "research=\(researchKey)"), server)
    let settings = snapshot(defaults)
    #expect(throws: AppStore.SetupCommitError.moveNotConfirmed) { try store.commitSetup(result, key: goodKey, chosen: ["research"], confirmMove: false) }
    #expect(snapshot(defaults) == settings && keys.all() == ["hermes": "old-key"] && store.bots.map(\.id) == [existing.id], "a move without confirmation writes nothing")
    #expect(throws: AppStore.SetupCommitError.saveFailed) { try store.commitSetup(result, key: goodKey, chosen: ["research"], confirmMove: true) }
    #expect(snapshot(defaults) == settings && keys.all() == ["hermes": "old-key"], "settings and keys are restored")
    #expect(store.bots.map(\.id) == [existing.id] && existing.hermesProfile == "default")
    #expect(throws: AppStore.SetupCommitError.nothingChosen) { try store.commitSetup(result, key: goodKey, chosen: [], confirmMove: true) }
    #expect(throws: AppStore.SetupCommitError.notTested) { try store.commitSetup(.init(outcome: .unreachable), key: goodKey, chosen: ["default"], confirmMove: true) }
}
