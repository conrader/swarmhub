import Foundation
import Security
import Testing
@testable import AgentApp

// P10d: availability (Tier 1 and Tier 2) on temp folders, the binding table, and both orders end to end with
// "Add bots from box" against a mock Hermes server (briefs/P10.md P10d 5).

@MainActor private func availability(_ world: GrokWorld, store: AppStore? = nil) async -> GrokAvailability? {
    let coordinator = makeCoordinator(world, store ?? world.store())
    await coordinator.scan()
    return coordinator.availability
}

/// The cache file whose slice key contains `marker` (the fixture's roster or a transcript).
private func cacheFile(_ world: GrokWorld, containing marker: String) throws -> URL {
    let names = try FileManager.default.contentsOfDirectory(atPath: world.location.cacheFolder.path)
    let name = try #require(names.first { GrokBase32.sliceKey(forFileName: $0)?.contains(marker) == true })
    return world.location.cacheFolder.appending(path: name)
}

@Test func tierOneLooksOnlyForTheAppOrItsDataFolder() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "AgentAppTests-tier1-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = GrokLocation(dataFolder: root.appending(path: "Grok Bot"), app: root.appending(path: "Grok Bot.app"))
    #expect(!GrokLocator(location: location, registeredApp: { nil }).isPresent)
    #expect(GrokLocator(location: location, registeredApp: { root }).isPresent)
    try FileManager.default.createDirectory(at: location.app, withIntermediateDirectories: true)
    #expect(GrokLocator(location: location, registeredApp: { nil }).isPresent)
    try FileManager.default.removeItem(at: location.app)
    try FileManager.default.createDirectory(at: location.dataFolder, withIntermediateDirectories: true)
    #expect(GrokLocator(location: location, registeredApp: { nil }).isPresent)
}

@MainActor @Test func theAvailabilityMatrix() async throws {
    // Ready, and app only (the data folder never written).
    #expect(await availability(try GrokWorld()) == .ready)
    let appOnly = try GrokWorld()
    try FileManager.default.removeItem(at: appOnly.location.dataFolder)
    #expect(await availability(appOnly) == .unavailable(.cache(.notFound)))
    // No roster: the cache holds transcripts only.
    let noRoster = try GrokWorld()
    try FileManager.default.removeItem(at: cacheFile(noRoster, containing: GrokProtocol.rosterSuffix))
    #expect(await availability(noRoster) == .unavailable(.cache(.noRoster)))
    // Signed out, and no Keychain item: the recent messages still import.
    let signedOut = try GrokWorld()
    try FileManager.default.removeItem(at: signedOut.location.secretsFile)
    #expect(await availability(signedOut) == .cacheOnly(.signedOut))
    let noItem = try GrokWorld()
    noItem.passwords.probeStatus = errSecItemNotFound
    #expect(await availability(noItem) == .cacheOnly(.keychainItemMissing))
    // A schema this app does not know.
    let changed = try GrokWorld()
    try Data(#"{"schemaVersion":99,"value":{"rows":7}}"#.utf8).write(to: cacheFile(changed, containing: GrokProtocol.rosterSuffix))
    #expect(await availability(changed) == .unavailable(.cache(.unrecognisedShape)))
    // Two accounts and no slot naming one.
    let twoAccounts = try GrokWorld()
    let roster = try cacheFile(twoAccounts, containing: GrokProtocol.rosterSuffix)
    let otherKey = try #require(GrokBase32.sliceKey(forFileName: roster.lastPathComponent))
        .replacingOccurrences(of: "acct-fake-0001", with: "acct-fake-0002")
    try FileManager.default.copyItem(at: roster, to: twoAccounts.location.cacheFolder.appending(path: GrokWorld.fileName(otherKey)))
    #expect(await availability(twoAccounts) == .unavailable(.cache(.needsAccountChoice(accounts: 2))))
    // A linked cache folder is never followed.
    let linked = try GrokWorld()
    let real = linked.root.appending(path: "elsewhere", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: linked.location.cacheFolder, to: real)
    try FileManager.default.createSymbolicLink(at: linked.location.cacheFolder, withDestinationURL: real)
    #expect(await availability(linked) == .unavailable(.cache(.symlinked)))
    // A folder this app may not read.
    let locked = try GrokWorld()
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.location.cacheFolder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.location.cacheFolder.path) }
    let unreadable = await availability(locked)
    #expect(unreadable == .unavailable(.cache(.folderUnreadable)))
    if case .unavailable(let reason) = unreadable { #expect(reason.offersFolderAccess) }
    // An account the signed-in one does not match: recent messages only.
    let mismatch = try GrokWorld(slot: "account-slot-synthetic", activeAccount: "someone-else")
    #expect(await availability(mismatch) == .cacheOnly(.cache(.accountMismatch)))
    // A store that cannot save.
    let world = try GrokWorld()
    let demo = AppStore(demoMode: true, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(await availability(world, store: demo) == .unavailable(.persistenceOff))
    #expect(world.passwords.reads == 0 && world.fake.requests.isEmpty)
}

@MainActor @Test func theBindingTableKeyOrNotServerOrNot() async throws {
    // (server set, key for Jarvis) → expected Jarvis profile; every other bot follows the same rule without a key.
    let cases: [(server: String?, key: Bool, jarvis: String?, plain: String?)] = [
        (nil, false, nil, nil), (nil, true, "grok-jarvis", nil),
        ("https://box.test/v1", false, "grok-jarvis", "grok-plain-bot"), ("https://box.test/v1", true, "grok-jarvis", "grok-plain-bot"),
    ]
    for entry in cases {
        let world = try GrokWorld()
        let defaults = isolatedDefaults()
        if let server = entry.server { defaults.set(server, forKey: "hermesBaseURL") }
        let keys = InMemoryKeyStore(entry.key ? ["hermes.grok-jarvis": "synthetic-key"] : [:])
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults)
        let coordinator = makeCoordinator(world, store)
        await coordinator.scan()
        coordinator.mode = .recent
        await coordinator.proceed()
        await coordinator.settled()
        let jarvis = try #require(store.bots.first { $0.grokSourceID == GrokRunIDs.jarvis })
        let plain = try #require(store.bots.first { $0.grokSourceID == GrokRunIDs.plain })
        #expect(jarvis.hermesProfile == entry.jarvis && plain.hermesProfile == entry.plain, "\(entry)")
        #expect(jarvis.isGrokHistoryOnly == (entry.jarvis == nil) && jarvis.hermesBaseURL == entry.server)
    }
}

/// A store on a mock Hermes server that serves the named profiles (multiplexing on).
@MainActor private func hermesStore(serving profiles: Set<String>) -> (AppStore, String) {
    let (host, session) = MockHermesProtocol.serve(hermesModelsHandler(multiplex: true, served: profiles))
    let defaults = isolatedDefaults()
    defaults.set("https://\(host)", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults,
                         hermesSession: session)
    return (store, host)
}

private let servedProfiles: Set<String> = ["grok-jarvis", "grok-finance-controller"]

@MainActor @Test func keysFirstThenImportEndsWithOneBotPerProfile() async throws {
    let world = try GrokWorld()
    let (store, _) = hermesStore(serving: servedProfiles)
    let added = await store.addBotsFromBox("grok-jarvis=key-one\ngrok-finance-controller=key-two")
    #expect(added.map(\.summary).allSatisfy { $0.hasPrefix("added") })
    #expect(store.bots.filter { $0.hermesProfile?.hasPrefix("grok-") == true }.count == 2)
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await runFull(coordinator)
    #expect(coordinator.step == .finished)
    let expected = [("grok-jarvis", "Jarvis", GrokRunIDs.jarvis), ("grok-finance-controller", "Finance Controller", GrokRunIDs.finance)]
    for (profile, name, id) in expected {
        let bound = store.bots.filter { $0.hermesProfile == profile }
        #expect(bound.count == 1, "\(profile)")
        // Adopted: the identity is Grok's, the history attached, the key still present.
        #expect(bound.first?.name == name && bound.first?.grokSourceID == id && (bound.first?.grokHistoryCount ?? 0) > 0)
        #expect(store.keyStore.hasKey(for: "hermes.\(profile)"))
    }
    #expect(coordinator.botOutcomes.map(\.connection) == [.live, .live, .needsKey])
}

@MainActor @Test func importFirstThenKeysEndsWithOneBotPerProfile() async throws {
    let world = try GrokWorld()
    let (store, _) = hermesStore(serving: servedProfiles)
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await runFull(coordinator)
    #expect(coordinator.botOutcomes.map(\.connection) == [.needsKey, .needsKey, .needsKey])
    let results = await coordinator.addKeys("grok-jarvis=key-one\ngrok-finance-controller=key-two\ngrok-plain-bot=key-three")
    #expect(results.count == 3)
    for profile in ["grok-jarvis", "grok-finance-controller", "grok-plain-bot"] {
        #expect(store.bots.filter { $0.hermesProfile == profile }.count == 1, "\(profile)")
    }
    #expect(store.bots.first { $0.hermesProfile == "grok-jarvis" }?.grokSourceID == GrokRunIDs.jarvis)
    // Plain Bot's profile is not on the server: measured, not assumed.
    #expect(coordinator.botOutcomes.map(\.connection) == [.live, .live, .profileNotOnServer])
}

@MainActor @Test func historyOnlyBotsTakeTheirPastedKeyInsteadOfGainingATwin() async throws {
    let world = try GrokWorld()
    let (host, session) = MockHermesProtocol.serve(hermesModelsHandler(multiplex: true, served: servedProfiles))
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(),
                         defaults: isolatedDefaults(), hermesSession: session)
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    #expect(coordinator.serverURL == nil)
    coordinator.mode = .recent
    await coordinator.proceed()
    await coordinator.settled()
    #expect(store.bots.first { $0.grokSourceID == GrokRunIDs.jarvis }?.isGrokHistoryOnly == true)
    _ = await coordinator.addKeys("grok-jarvis=key-one")
    #expect(store.bots.filter { $0.hermesProfile == "grok-jarvis" }.map(\.grokSourceID) == [GrokRunIDs.jarvis])
    #expect(!host.isEmpty)
}

@MainActor @Test func checkAgainBindsBotsOnceAServerIsSet() async throws {
    let world = try GrokWorld()
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    coordinator.mode = .recent
    await coordinator.proceed()
    await coordinator.settled()
    #expect(coordinator.botOutcomes.allSatisfy { $0.connection == .historyOnly })
    store.defaults.set("https://box.test/v1", forKey: "hermesBaseURL")
    await coordinator.checkConnectionsAgain()
    #expect(coordinator.botOutcomes.map(\.profile) == ["grok-jarvis", "grok-finance-controller", "grok-plain-bot"])
    #expect(coordinator.botOutcomes.allSatisfy { $0.connection == .needsKey })
}

@MainActor @Test func aReimportKeepsALocalRenameUnlessRefreshIsTicked() async throws {
    let world = try GrokWorld()
    let store = world.store(server: "https://box.test/v1")
    func importRecent(refresh: Bool) async {
        let coordinator = makeCoordinator(world, store)
        await coordinator.scan()
        coordinator.mode = .recent
        coordinator.refreshIdentity = refresh
        await coordinator.proceed()
        await coordinator.settled()
    }
    await importRecent(refresh: false)
    let jarvis = try #require(store.bots.first { $0.grokSourceID == GrokRunIDs.jarvis })
    jarvis.name = "My Jarvis"
    await importRecent(refresh: false)
    #expect(jarvis.name == "My Jarvis" && store.bots.filter { $0.grokSourceID == GrokRunIDs.jarvis }.count == 1)
    // The Found step already shows it as imported.
    let again = makeCoordinator(world, store)
    await again.scan()
    let item = try #require(again.items.first { $0.id == GrokRunIDs.jarvis })
    #expect(item.importedLines == 9 && item.importedAt != nil)
    await importRecent(refresh: true)
    #expect(jarvis.name == "Jarvis")
}
