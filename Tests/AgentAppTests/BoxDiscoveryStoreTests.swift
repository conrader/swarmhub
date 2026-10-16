import Foundation
import Testing
@testable import AgentApp

// P35 store level: discovery in a quiet turn, the derived-key fast path, the confirmed adoption batch (ok, partial,
// failed), the refusal rules, undo, the "not connected" list, launch discovery, the sample-bot removal and the setup
// window's scan. A synthetic Hermes answers chat turns (`ChatParityServer`) and `/p/<profile>/v1/models` for the derived
// keys of `served` profiles (`MockHermesProtocol`). The real manager text is used; nothing touches a real box.

private let managerKey = "fedcba9876543210fedcba9876543210"

private func block(_ json: String) -> String { "Done.\n```swarmhub\n\(json)\n```" }
private func listed(_ rows: [(String, Bool)]) -> String {
    block(#"{"op":"bots","list":["# + rows.map { #"{"name":"\#($0.0)","has_key":\#($0.1)}"# }.joined(separator: ",") + "]}")
}

/// Jarvis (manager, `grok-jarvis`) on a synthetic box; chat turns get `replies` in order (the last repeats); `served`
/// profiles answer their derived key (derived from `root`), `servedLater` ones only once a second chat turn ran (adopted).
@MainActor private func boxStore(replies: [String], served: Set<String>, servedLater: Set<String> = [], url: URL = temporaryStore(),
                                 keys: InMemoryKeyStore? = nil, derivedFrom root: String = managerKey) -> (AppStore, Bot, String, String) {
    let counter = LockedTrace()
    let (chat, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            counter.add("turn"); let reply = replies[min(counter.read().count, replies.count) - 1]
            return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])])
        }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-box"]]) }
        return .json(404, ["error": "no route"])
    }
    let probe = MockHermesProtocol.serve { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "p", parts[2...] == ["v1", "models"], served.contains(parts[1]) || (counter.read().count >= 2 && servedLater.contains(parts[1])) else {
            return (404, ["error": "no route"])
        }
        let expected = "Bearer " + BotManagerText.derivedKey(managerKey: root, botName: parts[1])
        return request.value(forHTTPHeaderField: "Authorization") == expected ? (200, ["data": [["id": parts[1]]]]) : (401, ["error": "bad key"])
    }
    let defaults = isolatedDefaults(); defaults.set("https://\(probe.host)", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in hermes },
                         keyStore: keys ?? InMemoryKeyStore(["hermes": "default-key", "hermes.grok-jarvis": managerKey]), defaults: defaults, hermesSession: probe.session)
    store.botProbeAttempts = 2; store.botProbeDelay = .milliseconds(5)
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis, chat, probe.host)
}

private func turns(_ host: String) -> [(input: String, instructions: String)] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { ($0.body?["input"] as? String ?? "", $0.body?["instructions"] as? String ?? "") }
}
private func probed(_ host: String) -> [String] { MockHermesProtocol.recorded(host).compactMap { $0.url?.path } }

// MARK: Discovery and the fast path

@Test @MainActor func discoveryAddsWhatAnswersAndListsTheRestQuietly() async throws {
    let url = temporaryStore()
    let (store, jarvis, chat, probe) = boxStore(replies: [listed([("default", true), ("grok-jarvis", true), ("cfo", true), ("krytyk", true), ("lowcost", false),
                                                                    ("mine", true), ("coder", true)])], served: ["cfo"], url: url)
    store.bots += [Bot(name: "Coder", backend: .hermes, hermesProfile: "coder"), Bot(name: "Atlas", isDemo: true), Bot(name: "Mira", isDemo: true)]
    store.typedKeyProfiles = ["mine"]
    let scan = try #require(await store.discoverBox(manager: jarvis))
    #expect(scan == BoxScan(listed: 7, added: ["cfo"], adoptable: ["krytyk", "lowcost"], needsKey: ["default", "mine"]))
    let cfo = try #require(store.bots.first { $0.hermesProfile == "cfo" })
    #expect(cfo.name == "Cfo" && cfo.adoptedKeyBackup == nil && store.keyStore.key(for: "hermes.cfo") == BotManagerText.derivedKey(managerKey: managerKey, botName: "cfo"))
    let target = store.connection(of: jarvis)
    #expect(store.boxProfiles[target]?.map { "\($0.name) \($0.state) \($0.hasKey)" } == ["default needsKey true", "mine needsKey true", "krytyk adoptable true", "lowcost adoptable false"])
    // Quiet: nothing in Jarvis' chat; the turn carried the list recipe only. One try per profile with a key, none for lowcost.
    #expect(jarvis.messages.isEmpty && !store.anyTurnRunning)
    let sent = try #require(turns(chat).first)
    #expect(turns(chat).count == 1 && sent.input == "List every bot on this box for SwarmHub." && sent.instructions.hasPrefix("You are Jarvis.\n\n"))
    #expect(sent.instructions.contains("Reading needs no confirmation") && !sent.instructions.contains("bots_adopted"))
    #expect(probed(probe).sorted() == ["/p/cfo/v1/models", "/p/krytyk/v1/models"])
    // D6: a real bot was added, so the sample bots are gone. No key in store.json.
    #expect(!store.bots.contains { $0.isDemo })
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(!saved.contains(BotManagerText.derivedKey(managerKey: managerKey, botName: "cfo")) && !saved.contains(managerKey))
}

@Test @MainActor func nothingLeftHidesTheSectionAndNoBlockChangesNothing() async throws {
    let (store, jarvis, _, _) = boxStore(replies: [listed([("grok-jarvis", true), ("cfo", true)]), "I could not run that."], served: ["cfo"])
    #expect(await store.discoverBox(manager: jarvis) == BoxScan(listed: 2, added: ["cfo"]))
    #expect(store.boxProfiles.isEmpty, "hidden when empty")
    #expect(await store.discoverBox(manager: jarvis) == nil && store.boxProfiles.isEmpty && store.bots.count == 2)
}

@Test @MainActor func aListAskedForInChatFeedsTheSameSection() async throws {
    let (store, jarvis, _, _) = boxStore(replies: [listed([("default", true), ("krytyk", true)])], served: [])
    #expect(store.send(text: "list bots"))
    try await waitUntil { !store.anyTurnRunning && !store.boxProfiles.isEmpty }
    #expect(store.boxProfiles[store.connection(of: jarvis)]?.map(\.name) == ["default", "krytyk"] && store.botOffers[jarvis.id] == nil)
}

@Test @MainActor func launchDiscoveryPicksAManagerAndRunsOncePerConnection() async throws {
    let (store, jarvis, chat, _) = boxStore(replies: [listed([("default", true), ("krytyk", true)])], served: [])
    jarvis.canManageBots = false
    let ermes = Bot(name: "Ermes", backend: .hermes, hermesProfile: "default")
    store.bots = [Bot(name: "Archive", backend: .hermes, hermesProfile: "nokey"), ermes, jarvis]
    await store.discoverBoxesOnLaunch()
    await store.discoverBoxesOnLaunch()
    #expect(store.isManager(ermes) && !store.isManager(jarvis), "the first connected bot with a key takes the role")
    #expect(turns(chat).count == 1 && store.boxProfiles[store.connection(of: ermes)]?.map(\.name) == ["krytyk"])
}

@Test @MainActor func addAllReportsAndOffersTheBatch() async throws {
    let (store, jarvis, _, _) = boxStore(replies: [listed([("default", true), ("grok-jarvis", true), ("krytyk", true)])], served: [])
    let found = await store.addAllBotsFromBoxes()
    #expect(found.lines == ["Found 3 bots; 1 to connect; 1 need their own key.", BoxCopy.mainBotKey])
    #expect(found.offer?.names == ["krytyk"] && found.offer?.managerID == jarvis.id && found.offer?.managerName == "Jarvis")
}

// MARK: Adoption

@Test @MainActor func disconnectedBotsCanBeSelectedWithoutConnectingOrSending() throws {
    let (store, jarvis, chat, probe) = boxStore(replies: ["unused"], served: [])
    let target = store.connection(of: jarvis)
    for state in [BoxProfile.State.needsKey, .adoptable, .failed, .adopting] {
        let profile = BoxProfile(name: "cfo", hasKey: true, state: state)
        store.boxProfiles[target] = [profile]
        store.open(profile, on: target)
        #expect(store.selectedDisconnectedProfile == profile && store.selectedBoxProfile?.target == target)
        #expect(store.selectedBot == nil && store.selectedGroup == nil && store.adoptionOffer == nil)
        #expect(!store.send(text: "Cannot send until connected"))
    }
    #expect(turns(chat).isEmpty && probed(probe).isEmpty)
    store.open(jarvis)
    #expect(store.selectedBoxProfile == nil && store.selectedBot === jarvis)
    store.open(try #require(store.boxProfiles[target]?.first), on: target)
    let group = GroupChat(name: "Crew", memberIDs: [jarvis.id]); store.groups = [group]; store.open(group)
    #expect(store.selectedBoxProfile == nil && store.selectedGroup === group)
}

@Test @MainActor func deletingDisconnectedBotsPersistsAndIsScopedToTheirBox() async throws {
    let (store, jarvis, chat, probe) = boxStore(replies: ["unused"], served: ["cfo"])
    let target = store.connection(of: jarvis), otherTarget = "https://other-box.example"
    let profile = BoxProfile(name: "cfo", hasKey: true, state: .adoptable)
    store.boxProfiles[target] = [profile]; store.boxProfiles[otherTarget] = [profile]
    store.open(profile, on: target); store.deleteBoxProfile(profile, on: target)
    #expect(store.boxProfiles[target] == nil && store.boxProfiles[otherTarget] == [profile])
    #expect(store.selectedBot === jarvis && store.selectedBoxProfile == nil)
    #expect(store.isDeletedBoxProfile("cfo", on: target) && !store.isDeletedBoxProfile("cfo", on: otherTarget))
    store.save()
    let relaunched = AppStore(storeURL: store.fileURL, autoConfigureHermes: false, keyStore: store.keyStore,
                              defaults: store.defaults, hermesSession: store.hermesSession)
    let manager = try #require(relaunched.bots.first { $0.id == jarvis.id })
    let scan = await relaunched.absorbListed([.init(name: "cfo", description: "", hasKey: true)], manager: manager)
    #expect(relaunched.bots.allSatisfy { !relaunched.orientationPending($0) }, "P49: box discovery never orients")
    #expect(scan.added.isEmpty && scan.adoptable.isEmpty && relaunched.boxProfiles.isEmpty)
    #expect(!relaunched.bots.contains { $0.hermesProfile == "cfo" })
    #expect(turns(chat).isEmpty && probed(probe).isEmpty, "deletion and rediscovery never connect or change the box")
}

@Test @MainActor func disconnectedNavigationAndDeletionKeepAValidSelection() {
    let (store, jarvis, _, _) = boxStore(replies: ["unused"], served: [])
    let target = store.connection(of: jarvis)
    let main = BoxProfile(name: "default", hasKey: true, state: .needsKey)
    let cfo = BoxProfile(name: "cfo", hasKey: true, state: .failed)
    store.boxProfiles[target] = [main, cfo]
    store.moveChatSelection(by: 1)
    #expect(store.selectedDisconnectedProfile == main && store.visibleChatCount == 3)
    store.moveChatSelection(by: 1)
    #expect(store.selectedDisconnectedProfile == cfo)
    store.moveChatSelection(by: 1)
    #expect(store.selectedBot === jarvis && store.selectedBoxProfile == nil)
    store.bots = []; store.open(main, on: target); store.deleteBoxProfile(main, on: target)
    #expect(store.selectedDisconnectedProfile == cfo)
    store.deleteBoxProfile(cfo, on: target)
    #expect(store.selectedBoxProfile == nil && store.selectedBot == nil && store.selectedGroup == nil)
}

@Test @MainActor func deletingCannotInterruptAnAdoptionAndAddAllCanRestoreDeletedProfiles() async throws {
    let (store, jarvis, _, _) = boxStore(replies: [listed([("cfo", false)])], served: [])
    let target = store.connection(of: jarvis), profile = BoxProfile(name: "cfo", hasKey: false, state: .adoptable)
    store.boxProfiles[target] = [profile]
    store.setBoxState(["cfo"], .adopting, on: target)
    store.deleteBoxProfile(profile, on: target)
    #expect(store.boxProfiles[target]?.first?.state == .adopting && !store.isDeletedBoxProfile("cfo", on: target))
    store.setBoxState(["cfo"], .failed, on: target); store.deleteBoxProfile(profile, on: target)
    #expect(store.boxProfiles[target] == nil)
    let found = await store.addAllBotsFromBoxes()
    #expect(found.offer?.names == ["cfo"] && store.boxProfiles[target]?.first?.state == .adoptable)
    #expect(!store.isDeletedBoxProfile("cfo", on: target))
}

@MainActor private func adopt(_ store: AppStore, _ names: [String], manager: Bot) async throws {
    #expect(store.startAdoption(names, manager: manager))
    try await waitUntil { !store.anyTurnRunning && store.pendingAdoptions.isEmpty && manager.messages.last?.role == .system }
}

@Test @MainActor func adoptionBatchAddsTheOkOnesAndListsTheFailedOnes() async throws {
    let reply = block(#"{"op":"bots_adopted","results":[{"name":"krytyk","ok":true,"backup":".env.swarmhub-bak-20261015T101500Z"},"#
                      + #"{"name":"lowcost","ok":true,"backup":""},{"name":"wingman","ok":true,"backup":".env.swarmhub-bak-20261015T101500Z"},"#
                      + #"{"name":"sekretarz","ok":false,"backup":""},{"name":"intruder","ok":true,"backup":""}]}"#)
    let (store, jarvis, chat, _) = boxStore(replies: [reply], served: ["krytyk", "lowcost", "intruder"])
    store.typedKeyProfiles = ["mine"]
    let target = store.connection(of: jarvis)
    store.boxProfiles[target] = ["krytyk", "lowcost", "wingman", "sekretarz"].map { BoxProfile(name: $0, hasKey: true, state: .adoptable) }
    try await adopt(store, ["krytyk", "lowcost", "wingman", "sekretarz", "default", "grok-jarvis", "mine"], manager: jarvis)
    let sent = try #require(turns(chat).first)
    #expect(sent.input == "Connect Krytyk, Lowcost, Wingman, Sekretarz to SwarmHub.")
    #expect(sent.instructions.contains("for N in krytyk lowcost wingman sekretarz; do") && sent.instructions.contains("That press is his yes"))
    #expect(jarvis.messages.first { $0.role == .user }?.content == sent.input, "a visible turn in the manager's chat")
    #expect(store.bots.first { $0.hermesProfile == "krytyk" }?.adoptedKeyBackup == ".env.swarmhub-bak-20261015T101500Z")
    #expect(store.bots.first { $0.hermesProfile == "lowcost" }?.adoptedKeyBackup == "")
    #expect(store.keyStore.key(for: "hermes.lowcost") == BotManagerText.derivedKey(managerKey: managerKey, botName: "lowcost"))
    #expect(!store.bots.contains { $0.hermesProfile == "intruder" }, "only names SwarmHub asked for")
    #expect(!store.bots.contains { ["wingman", "sekretarz"].contains($0.hermesProfile ?? "") }, "ok without an answering key, or not ok: failed")
    #expect(store.boxProfiles[target]?.map { "\($0.name) \($0.state)" } == ["wingman failed", "sekretarz failed"])
    #expect(jarvis.messages.last?.content == "Connected Krytyk, Lowcost. Couldn’t connect Wingman, Sekretarz; they are listed under “not connected”.")
}

@Test @MainActor func aWhollyFailedBatchAddsNothingAndRetryOffersOneBot() async throws {
    let (store, jarvis, _, _) = boxStore(replies: [block(#"{"op":"bots_adopted","results":[{"name":"cfo","ok":false,"backup":""}]}"#)], served: [])
    let target = store.connection(of: jarvis)
    store.boxProfiles[target] = [BoxProfile(name: "default", hasKey: true, state: .needsKey), BoxProfile(name: "cfo", hasKey: true, state: .adoptable)]
    try await adopt(store, ["cfo"], manager: jarvis)
    #expect(store.bots.count == 1 && store.boxProfiles[target]?.last?.state == .failed && jarvis.messages.last?.content.hasPrefix("Couldn’t connect Cfo") == true)
    // D5: Connect on the failed row offers that one bot again; the main bot's row only offers its key.
    store.offerAdoption(try #require(store.boxProfiles[target]?.last), on: target)
    #expect(store.adoptionOffer?.names == ["cfo"] && store.adoptionOffer?.managerName == "Jarvis")
    store.adoptionOffer = nil
    store.offerAdoption(try #require(store.boxProfiles[target]?.first), on: target)
    #expect(store.adoptionOffer == nil)
}

@Test @MainActor func adoptionRefusesTheMainBotTheManagerAndTypedKeys() {
    let (store, jarvis, chat, _) = boxStore(replies: ["never"], served: [])
    store.typedKeyProfiles = ["mine"]
    store.bots.append(Bot(name: "Bound", backend: .hermes, hermesProfile: "bound"))
    #expect(!store.startAdoption(["default", "grok-jarvis", "mine", "bound", "Not Valid"], manager: jarvis))
    #expect(!store.startAdoption(["cfo"], manager: Bot(name: "Stranger", backend: .hermes, hermesProfile: "stranger")), "only a manager runs it")
    #expect(turns(chat).isEmpty && jarvis.messages.isEmpty && store.pendingSkillInstalls.isEmpty)
}

// MARK: Undo

@Test @MainActor func undoRestoresTheBackupThenForgetsTheKey() async throws {
    let (store, jarvis, chat, _) = boxStore(replies: [block(#"{"op":"key_restored","name":"krytyk","ok":true}"#)], served: [])
    let krytyk = Bot(name: "Krytyk", backend: .hermes, messages: [ChatMessage(role: .user, content: "hej")], hermesProfile: "krytyk")
    krytyk.adoptedKeyBackup = ".env.swarmhub-bak-20261015T101500Z"; store.bots.append(krytyk)
    store.keyStore.setKey("derived", for: "hermes.krytyk")
    #expect(!store.restoreOldKey(jarvis), "the manager has nothing to restore")
    #expect(store.restoreOldKey(krytyk))
    try await waitUntil { !store.anyTurnRunning && krytyk.adoptedKeyBackup == nil }
    let sent = try #require(turns(chat).first)
    #expect(sent.input == "Restore Krytyk’s old key." && sent.instructions.contains("N=krytyk; B=.env.swarmhub-bak-20261015T101500Z;"))
    #expect(store.keyStore.key(for: "hermes.krytyk").isEmpty && store.bots.contains(krytyk) && krytyk.messages.map(\.content) == ["hej"])
    #expect(jarvis.messages.last?.content == BoxCopy.restored("Krytyk"))
    #expect(!store.restoreOldKey(krytyk), "once restored there is nothing to undo")
}

@Test @MainActor func aFailedUndoKeepsTheKey() async throws {
    let (store, jarvis, _, _) = boxStore(replies: [block(#"{"op":"key_restored","name":"lowcost","ok":false}"#)], served: [])
    let lowcost = Bot(name: "Lowcost", backend: .hermes, hermesProfile: "lowcost"); lowcost.adoptedKeyBackup = ""
    store.bots.append(lowcost); store.keyStore.setKey("derived", for: "hermes.lowcost")
    #expect(store.restoreOldKey(lowcost))
    try await waitUntil { !store.anyTurnRunning && jarvis.messages.last?.role == .system }
    #expect(store.keyStore.key(for: "hermes.lowcost") == "derived" && lowcost.adoptedKeyBackup == "" && jarvis.messages.last?.content == BoxCopy.restoreFailed("Lowcost"))
}

// MARK: Sample bots (D6)

@Test @MainActor func launchDropsSampleBotsOnceRealBotsExist() throws {
    let url = temporaryStore(), defaults = isolatedDefaults()
    let atlas = Bot(name: "Atlas", messages: [ChatMessage(role: .user, content: "sample chat")], isDemo: true)
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), group = GroupChat(name: "Crew", memberIDs: [atlas.id, jarvis.id])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(StoreFile(bots: [atlas, jarvis], groups: [group])).write(to: url)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(store.bots.map(\.name) == ["Jarvis"] && store.groups.first?.memberIDs == [jarvis.id] && defaults.bool(forKey: AppStore.samplesMigrationKey))
    #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("sample chat"), "their chats are not kept")
    // Samples only: kept, and "Look around with sample agents" still makes them.
    let samplesURL = temporaryStore(), samplesDefaults = isolatedDefaults()
    let looking = AppStore(storeURL: samplesURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: samplesDefaults)
    looking.loadSamples()
    #expect(looking.bots.count == 5 && looking.bots.allSatisfy(\.isDemo))
    let reopened = AppStore(storeURL: samplesURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: samplesDefaults)
    #expect(reopened.bots.count == 5)
}

// MARK: Setup window

@Test @MainActor func setupScanAddsDerivedBotsMakesTheMainBotTheManagerAndConnectsTheRest() async throws {
    let typed = "typed-main-key"
    let adopted = block(#"{"op":"bots_adopted","results":[{"name":"krytyk","ok":true,"backup":".env.swarmhub-bak-20261015T101500Z"},{"name":"lowcost","ok":true,"backup":""}]}"#)
    let (store, _, chat, probe) = boxStore(replies: [listed([("default", true), ("cfo", true), ("krytyk", true), ("lowcost", false)]), adopted],
                                           served: ["cfo"], servedLater: ["krytyk", "lowcost"], keys: InMemoryKeyStore(), derivedFrom: typed)
    store.bots = [Bot(name: "Atlas", isDemo: true)]; store.selectedBot = nil
    store.defaults.removeObject(forKey: "hermesBaseURL")
    let box = try #require(URL(string: "https://\(probe)"))
    let result = SetupCheckResult(outcome: .connected(place: probe, count: 1), baseURL: box,
                                  probes: [HermesProfileProbe(id: "default", status: .available(.init(id: "default", name: "Ermes", model: "hermes-agent")))])
    var flow = SetupFlow(prefill: .init(startAtAddress: true)); flow.input.key = typed
    flow.apply(.test(result)); flow.preselect(alreadyAdded: store.addedProfileIDs)
    flow.apply(.boxScanned(await store.scanBoxForSetup(result, key: typed)))
    let scan = try #require(flow.boxScan)
    #expect(scan == SetupBoxScan(managerName: "Ermes", managerProfile: "default", managerIsNew: true, listed: 4, derived: ["cfo"], adoptable: ["krytyk", "lowcost"]))
    #expect(store.keyStore.key(for: "hermes.cfo").isEmpty && store.bots.count == 1, "nothing is stored before Add")
    let added = try store.commitSetup(result, key: typed, chosen: flow.chosen, confirmMove: false, scan: scan)
    #expect(added.map(\.hermesProfile) == ["default", "cfo"] && store.keyStore.key(for: "hermes.cfo") == BotManagerText.derivedKey(managerKey: typed, botName: "cfo"))
    let ermes = try #require(added.first)
    #expect(store.isManager(ermes) && store.typedKeyProfiles.contains("default") && !store.bots.contains { $0.isDemo })
    #expect(store.boxProfiles[store.connection(of: ermes)]?.map(\.name) == ["krytyk", "lowcost"])
    #expect(store.startAdoption(scan.adoptable, manager: ermes))
    try await waitUntil { !store.anyTurnRunning && store.bots.count == 4 }
    #expect(store.bots.allSatisfy { !store.orientationPending($0) }, "P49: the setup scan and adoption never orient")
    #expect(turns(chat).last?.instructions.contains("MK=$(grep '^API_SERVER_KEY=' ~/.hermes/.env") == true)
    #expect(store.boxProfiles.isEmpty && store.bots.compactMap(\.adoptedKeyBackup) == [".env.swarmhub-bak-20261015T101500Z", ""])
}
