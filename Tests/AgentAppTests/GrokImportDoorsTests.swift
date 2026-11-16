import Foundation
import Security
import Testing
@testable import AgentApp

// Availability (Tier 1 and Tier 2) on temp folders, and a re-import that keeps a local rename.

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
    let demo = AppStore(demoMode: true, storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(await availability(world, store: demo) == .unavailable(.persistenceOff))
    #expect(world.passwords.reads == 0 && world.fake.requests.isEmpty)
}

@MainActor @Test func aReimportKeepsALocalRenameUnlessRefreshIsTicked() async throws {
    let world = try GrokWorld()
    let store = world.store(server: "http://127.0.0.1:8787")
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
