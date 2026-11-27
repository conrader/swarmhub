import Foundation
import Testing
@testable import AgentApp

// autoctx1: a store.json set aside as unreadable (`store.json.corrupt-*`) or a backup next to it is offered back in a
// chat-style prompt; SwarmHub never seeds its default 127.0.0.1 bot over it. Temporary directories only.

/// A server that is set up, and a store directory that does not exist yet.
private func setup() throws -> (url: URL, defaults: UserDefaults) {
    let defaults = isolatedDefaults(); defaults.set("http://127.0.0.1:8787", forKey: HerdrServerList.legacyAddressKey)
    let url = temporaryStore(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (url, defaults)
}

/// Writes a real store with `names` (the way SwarmHub saves one) at `file` beside `store`.
@MainActor private func writeStore(_ names: [String], as file: String, beside store: URL, modified: Date? = nil) throws -> URL {
    let scratch = temporaryStore()
    try FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = AppStore(storeURL: scratch, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    writer.bots = names.map { Bot(name: $0, backend: .herdr) }
    writer.save()
    let target = store.deletingLastPathComponent().appending(path: file)
    try FileManager.default.moveItem(at: scratch, to: target)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path) }
    return target
}

@MainActor private func launch(_ url: URL, _ defaults: UserDefaults) -> AppStore {
    AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
}

@Test @MainActor func aMissingStoreWithACorruptCopyIsOfferedAndNoDefaultBotIsSeeded() throws {
    let (url, defaults) = try setup()
    let corrupt = try writeStore(["Boppy", "Jarvis", "Swarmhub"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    let store = launch(url, defaults)
    #expect(store.bots.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let offer = try #require(store.storeRestoreOffer)
    #expect(offer.url.lastPathComponent == corrupt.lastPathComponent && offer.botCount == 3)
    #expect(offer.entries.map(\.name) == ["Boppy", "Jarvis", "Swarmhub"])
}

@Test @MainActor func withNothingToRestoreTheStoreStartsEmpty() throws {
    let (url, defaults) = try setup()
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer == nil)
    #expect(store.bots.isEmpty && !FileManager.default.fileExists(atPath: url.path), "nothing is seeded and nothing is written")
}

@Test @MainActor func anUnreadableStoreIsSetAsideAndANewerBackupIsOffered() throws {
    let (url, defaults) = try setup()
    _ = try writeStore(["Old"], as: "store.json.corrupt-2026-10-01T00-00-00Z", beside: url, modified: Date(timeIntervalSinceNow: -86_400 * 20))
    _ = try writeStore(["Boppy", "Jarvis"], as: "store.json.backup-reconcile-1", beside: url, modified: Date(timeIntervalSinceNow: -3_600))
    try Data("{ not json".utf8).write(to: url)
    let store = launch(url, defaults)
    #expect(store.bots.isEmpty)
    let offer = try #require(store.storeRestoreOffer)
    #expect(offer.url.lastPathComponent == "store.json.backup-reconcile-1" && offer.botNames == ["Boppy", "Jarvis"])
    // The unreadable file itself was moved aside, not deleted.
    let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(names.filter { $0.hasPrefix("store.json.corrupt-") }.count == 2)
}

@Test @MainActor func startFreshKeepsTheCorruptCopy() throws {
    let (url, defaults) = try setup()
    let corrupt = try writeStore(["Boppy"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer != nil && store.bots.isEmpty)
    store.declineStoreRestore()
    #expect(store.storeRestoreOffer == nil && store.bots.isEmpty)
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
    // Answered once: the next launch does not ask again.
    #expect(launch(url, defaults).storeRestoreOffer == nil)
}

@Test @MainActor func aStoreWithRealBotsIsNeverOfferedAnything() throws {
    let (url, defaults) = try setup()
    _ = try writeStore(["Boppy", "Jarvis"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    _ = try writeStore(["Mine"], as: "store.json", beside: url)
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer == nil && store.bots.map(\.name) == ["Mine"])
}

@Test @MainActor func startFreshAfterAnUnreadableStoreSavesAgainAndKeepsTheUnreadableFile() throws {
    let (url, defaults) = try setup()
    let directory = url.deletingLastPathComponent()
    let backup = try writeStore(["Boppy", "Jarvis"], as: "store.json.backup-reconcile-1", beside: url, modified: Date(timeIntervalSinceNow: -3_600))
    let unreadable = Data("{ not json".utf8)
    try unreadable.write(to: url)
    let store = launch(url, defaults)
    let corrupt = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first(where: { $0.hasPrefix("store.json.corrupt-") }))
    #expect(store.storeRestoreOffer != nil && store.bots.isEmpty)
    store.declineStoreRestore()
    // Saving is back: a change made after it is on disk.
    #expect(store.bots.isEmpty)
    store.addBot(name: "Fresh", persona: "", backend: .herdr, avatarName: nil)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let next = launch(url, defaults)
    #expect(next.bots.map(\.name) == ["Fresh"] && next.storeRestoreOffer == nil)
    // The unreadable file and the backup are where they were, unchanged.
    #expect(try Data(contentsOf: directory.appending(path: corrupt)) == unreadable)
    #expect(FileManager.default.fileExists(atPath: backup.path))
}

@Test @MainActor func newerUnusableCopiesNeverHideAnOlderGoodBackup() throws {
    let (url, defaults) = try setup()
    let directory = url.deletingLastPathComponent()
    _ = try writeStore(["Boppy", "Jarvis"], as: "store.json.backup-old", beside: url, modified: Date(timeIntervalSinceNow: -86_400 * 30))
    // Eight newer copies this build cannot use: seven unreadable ones and one that holds no bots.
    _ = try writeStore([], as: "store.json.backup-empty", beside: url, modified: Date(timeIntervalSinceNow: -600))
    for index in 0..<7 {
        let bad = directory.appending(path: "store.json.corrupt-2026-10-2\(index)T00-00-00Z")
        try Data("{ not json \(index)".utf8).write(to: bad)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -Double(index) * 60)], ofItemAtPath: bad.path)
    }
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer?.url.lastPathComponent == "store.json.backup-old" && store.storeRestoreOffer?.botCount == 2)
    #expect(store.bots.isEmpty)
    // The bounds: only the `limit` newest files are tried, and none bigger than `maxBytes`.
    #expect(StoreRestore.offer(store: url, resolvedThrough: nil, limit: 8) == nil)
    #expect(StoreRestore.offer(store: url, resolvedThrough: nil, limit: 9)?.url.lastPathComponent == "store.json.backup-old")
    #expect(StoreRestore.offer(store: url, resolvedThrough: nil, maxBytes: 64) == nil)
}

@Test @MainActor func restoreLoadsTheSetAsideStoreAndKeepsTheCopy() throws {
    let (url, defaults) = try setup()
    let corrupt = try writeStore(["Boppy", "Jarvis"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    let store = launch(url, defaults)
    #expect(store.restoreSetAsideStore())
    #expect(store.storeRestoreOffer == nil && store.storeRestoreNote == StoreRestoreCopy.restored(2))
    #expect(Set(store.bots.map(\.name)) == ["Boppy", "Jarvis"])
    // Saved as store.json, and the next launch opens it without asking again.
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
    let next = launch(url, defaults)
    #expect(Set(next.bots.map(\.name)) == ["Boppy", "Jarvis"] && next.storeRestoreOffer == nil)
}

@Test @MainActor func aRestoredGoalCanRunAfterTwoRelaunchesAndStopsOnceOnRequest() async throws {
    let (url, defaults) = try setup()
    let writer = launch(url, defaults)
    let bot = Bot(name: "Reviewer", backend: .herdr)
    let goal = ChatGoal(objective: "Review the saved report", destination: writer.goalDestination(for: bot))
    bot.goal = goal
    writer.bots = [bot]
    writer.pendingHerdrEndings = [try #require(writer.herdrEnding(for: bot))]
    try writer.writeStore()
    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("backup"))

    let backend = TestBackend(streamMode: .longRunning)
    func reopen() -> AppStore {
        let store = AppStore(storeURL: url, autoStart: true, backendFactory: { _ in backend },
                             keyStore: InMemoryKeyStore(), defaults: defaults)
        store.herdrClientSetup = { $0.session = UnreachableProtocol.session }
        return store
    }
    var store = reopen()
    try #require(store.restoreSetAsideStore())
    store.startLaunchWork(makeConnectivity: { nil })
    for _ in 0..<2 {
        store = reopen()
        store.startLaunchWork(makeConnectivity: { nil })
        #expect(store.pendingHerdrEndings.isEmpty)
        #expect(store.selectedBot?.goal?.state == .waiting)
    }
    let restored = try #require(store.selectedBot)
    #expect(restored.id == bot.id && restored.goal?.id == goal.id)
    #expect(backend.calls.all.isEmpty)
    store.resumeGoal(in: restored)
    try #require(restored.goal?.state == .running)
    try await backend.calls.wait { $0.contains("send") }
    try #require(store.handleGoalCommand(.stop, in: restored) == nil)
    try await waitUntil { store.isIdle(restored) && store.turns.pendingInterrupts[restored.id] == nil }
    #expect(backend.calls.all == ["send", "capture", "post", "post:run-1"])
    let saved = try StoreFile.decode(Data(contentsOf: url))
    #expect(saved.bots.first?.goal?.state == .stopped)
}

@Test @MainActor func anUnsupportedStoreIsSetAsideWholeWithoutRewritingIt() throws {
    let (url, defaults) = try setup()
    let valid = try JSONEncoder().encode(StoreFile(bots: [Bot(name: "Current", backend: .herdr)], groups: []))
    var file = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    let bots = try #require(file["bots"] as? [[String: Any]])
    var unsupported = try #require(bots.first)
    unsupported["id"] = UUID().uuidString
    unsupported["backend"] = "Unsupported"
    file["bots"] = bots + [unsupported]
    let original = try JSONSerialization.data(withJSONObject: file)
    try original.write(to: url)

    let store = launch(url, defaults)
    #expect(store.bots.isEmpty && store.persistenceEnabled)
    #expect(store.unreadableStoreSetAside && store.storeRestoreOffer == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let directory = url.deletingLastPathComponent()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let preserved = try #require(files.first { $0.lastPathComponent.hasPrefix("store.json.corrupt-") })
    #expect(try Data(contentsOf: preserved) == original)
    #expect(FirstRun.settle(store))
    store.addBot(name: "Fresh", persona: "", backend: .herdr, avatarName: nil)
    #expect(launch(url, defaults).bots.map(\.name) == ["Fresh"])
    #expect(try Data(contentsOf: preserved) == original)
}

@Test @MainActor func aReadOnlyOpenLeavesAnUnreadableStoreInPlace() throws {
    let (url, defaults) = try setup()
    let original = Data("{ not json".utf8)
    try original.write(to: url)

    let store = AppStore(storeURL: url, autoStart: false, readOnly: true, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(!store.persistenceEnabled && !store.unreadableStoreSetAside)
    #expect(store.errorMessage != nil)
    #expect(try Data(contentsOf: url) == original)
}

@Test func aVersionOneStoreWithSupportedBotsStillDecodes() throws {
    let data = try JSONEncoder().encode([Bot(name: "Current", backend: .herdr, sessionID: "session-1")])
    let file = try StoreFile.decode(data)
    #expect(file.version == 1 && file.bots.map(\.name) == ["Current"] && file.groups.isEmpty)
    #expect(file.bots.first?.sessionID == "session-1")
}

@Test @MainActor func aMixedStoreLoadsHerdrBotsAndAHealthyEmptyStoreDoesNotOfferABackup() throws {
    let (url, defaults) = try setup()
    let current = Bot(name: "Current", backend: .herdr, sessionID: "session-1")
    let hermesID = UUID()
    let group = GroupChat(name: "Team", memberIDs: [current.id, hermesID])
    group.sessions[hermesID.uuidString.lowercased()] = "retired-session"
    let retiredMessages = try JSONSerialization.jsonObject(with: JSONEncoder().encode([ChatMessage(role: .user, content: "Old transcript")]))
    let data = try JSONEncoder().encode(StoreFile(bots: [current], groups: [group]))
    var mixed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let bots = try #require(mixed["bots"] as? [[String: Any]]) + [
        ["backend": "Hermes Agent", "id": hermesID.uuidString, "name": "Hermes", "messages": retiredMessages],
        ["backend": "OpenClaw", "id": UUID().uuidString],
    ]
    mixed["bots"] = bots
    let original = try JSONSerialization.data(withJSONObject: mixed)
    let versionOne = try StoreFile.decode(JSONSerialization.data(withJSONObject: bots))
    #expect(versionOne.version == 1 && versionOne.bots.count == 3)
    #expect(versionOne.bots.first { $0.id == hermesID }?.messages.first?.content == "Old transcript")

    try original.write(to: url)
    let loaded = launch(url, defaults)
    #expect(loaded.persistenceEnabled && loaded.storeRestoreOffer == nil)
    #expect(loaded.bots.first?.id == current.id && loaded.bots.first?.sessionID == "session-1")
    #expect(loaded.groups.first?.memberIDs == [current.id, hermesID])
    #expect(loaded.groups.first?.session(for: hermesID) == "retired-session")
    #expect(loaded.routingMembers(of: group).map(\.id) == [current.id])
    loaded.save()
    let archived = try #require(launch(url, defaults).bots.first(where: { $0.id == hermesID }))
    #expect(archived.isReadOnlyArchive && archived.messages.first?.content == "Old transcript")
    let preMigration = try #require(StoreRestore.candidates(for: url).first { $0.lastPathComponent.contains("before-herdr-only") })
    #expect(try Data(contentsOf: preMigration) == original)

    let backup = url.appendingPathExtension("corrupt-fixture")
    try FileManager.default.moveItem(at: url, to: backup)
    mixed["bots"] = Array(bots.dropFirst())
    try JSONSerialization.data(withJSONObject: mixed).write(to: url)
    let store = launch(url, defaults)
    #expect(store.persistenceEnabled && store.bots.allSatisfy(\.isReadOnlyArchive))
    #expect(store.storeRestoreOffer == nil)
    #expect(try StoreFile.decode(Data(contentsOf: backup)).bots.count == 3)
}

@Test @MainActor func aHealthyGrokImportStoreSupersedesOlderBackupsAcrossLaunches() throws {
    let (url, defaults) = try setup()
    let names = (1...25).map { "Imported agent \($0)" }
    _ = try writeStore(["Old"], as: "store.json.corrupt-previous", beside: url, modified: Date(timeIntervalSinceNow: -3_600))
    _ = try writeStore(names, as: "store.json", beside: url)
    let healthy = try Data(contentsOf: url)

    let store = launch(url, defaults)
    #expect(store.bots.count == 25 && store.storeRestoreOffer == nil)
    store.declineStoreRestore()
    #expect(!store.restoreSetAsideStore())
    #expect(try Data(contentsOf: url) == healthy)

    try FileManager.default.removeItem(at: url)
    #expect(launch(url, defaults).storeRestoreOffer?.botNames == ["Old"])
}

@Test @MainActor func skipSuppressesEveryExistingBackupAndLeavesAConcurrentLiveStoreIntact() throws {
    let (url, defaults) = try setup()
    _ = try writeStore(["Old"], as: "store.json.bak-old", beside: url)
    _ = try writeStore(["Other"], as: "store.json.seed-old", beside: url)
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer != nil)
    _ = try writeStore(["Current"], as: "store.json", beside: url)
    let healthy = try Data(contentsOf: url)
    store.declineStoreRestore()
    store.save()
    #expect(try Data(contentsOf: url) == healthy)
    try FileManager.default.removeItem(at: url)
    #expect(launch(url, defaults).storeRestoreOffer == nil)
}

@Test @MainActor func restoringNeverReplacesAStoreSavedWhileThePromptWasOpen() throws {
    let (url, defaults) = try setup()
    _ = try writeStore(["Old"], as: "store.json.bak-old", beside: url)
    let store = launch(url, defaults)
    _ = try writeStore(["New"], as: "store.json", beside: url)
    let healthy = try Data(contentsOf: url)
    #expect(!store.restoreSetAsideStore())
    store.save()
    #expect(try Data(contentsOf: url) == healthy)
    #expect(launch(url, defaults).storeRestoreOffer == nil)
}

@Test @MainActor func aBackupThatBecomesUnreadableDoesNotLeaveSetupBlocked() throws {
    let (url, defaults) = try setup()
    let backup = try writeStore(["Old"], as: "store.json.bak-old", beside: url)
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer != nil && !store.persistenceEnabled)
    try Data("unreadable".utf8).write(to: backup)
    #expect(!store.restoreSetAsideStore())
    #expect(store.storeRestoreOffer == nil && store.persistenceEnabled)
    #expect(FirstRun.settle(store))
}

@Test @MainActor func recoveringRetainsSmallerLargerAndUnreadableCopies() throws {
    let (url, defaults) = try setup()
    let directory = url.deletingLastPathComponent()
    let backups = directory.appending(path: "backups")
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
    let oldDate = Date(timeIntervalSinceNow: -3_600)
    let old = try writeStore(["Old"], as: "store.json.bak-old", beside: url, modified: oldDate)
    let newest = try writeStore(["Latest"], as: "store.json.bak-new", beside: url, modified: Date(timeIntervalSinceNow: -60))
    let otherSet = try writeStore(["Seed"], as: "store.json.seed-old", beside: url, modified: oldDate)
    let bad = directory.appending(path: "store.json.bak-interrupted")
    try Data("incomplete".utf8).write(to: bad)
    let subStore = backups.appending(path: "store.json")
    let oldSub = try writeStore(["Old in backups"], as: "store.json.bak-first", beside: subStore, modified: oldDate)
    let newSub = try writeStore(["Current in backups"], as: "store.json.bak-last", beside: subStore)
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer?.url.resolvingSymlinksInPath().path == newSub.resolvingSymlinksInPath().path)
    for copy in [newest, bad, otherSet, newSub] { #expect(FileManager.default.fileExists(atPath: copy.path)) }
    for copy in [old, oldSub] { #expect(FileManager.default.fileExists(atPath: copy.path)) }
}

@Test @MainActor func restoreReviewsAMigratedSnapshotAndUndoSurvivesRelaunch() throws {
    let (url, defaults) = try setup()
    let legacy = Bot(name: "Old Grok group", messages: [ChatMessage(role: .user, content: "Saved line")])
    legacy.archivedMembers = ["Jarvis"]
    legacy.grokHistoryCount = 3
    let backup = url.appendingPathExtension("bak-grok")
    try JSONEncoder().encode([legacy]).write(to: backup)
    let store = launch(url, defaults)
    let offer = try #require(store.storeRestoreOffer)
    #expect(offer.botCount == 0)
    #expect(offer.entries == [.init(id: legacy.id, name: legacy.name, kind: "Group", messages: 1, archiveLines: nil, expectsArchive: true)])

    #expect(store.restoreSetAsideStore())
    #expect(store.bots.isEmpty && store.groups.first?.messages.first?.content == "Saved line")
    let reopened = launch(url, defaults)
    #expect(reopened.storeRestoreOffer == nil && reopened.restoreUndoRevision != nil)
    reopened.undoStoreRestore()
    #expect(reopened.groups.isEmpty && !FileManager.default.fileExists(atPath: url.path))
    #expect(FileManager.default.fileExists(atPath: backup.path))
    #expect(launch(url, defaults).storeRestoreOffer == nil)
}

@Test @MainActor func aChangedSnapshotAndGroupOnlyLiveDataBothPreventRestore() throws {
    let (url, defaults) = try setup()
    let backup = try writeStore(["One"], as: "store.json.bak-review", beside: url)
    let store = launch(url, defaults)
    try JSONEncoder().encode(StoreFile(bots: [Bot(name: "Other")], groups: [])).write(to: backup)
    #expect(!store.restoreSetAsideStore())
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let group = GroupChat(name: "Healthy group", memberIDs: [])
    try JSONEncoder().encode(StoreFile(bots: [], groups: [group])).write(to: url)
    #expect(launch(url, defaults).storeRestoreOffer == nil)
    #expect(!store.restoreSetAsideStore())
    #expect(try StoreFile.decode(Data(contentsOf: url)).groups.first?.id == group.id)
}

@Test @MainActor func aPendingRecoveryLeavesTheLedgerAndServerRegistrationUntouched() async throws {
    let (url, defaults) = try setup()
    let writer = launch(url, defaults)
    let bot = Bot(name: "Existing", backend: .herdr)
    let queued = ChatMessage(role: .user, content: "Keep waiting")
    queued.metadata[TurnWaitCopy.key] = "waiting"
    bot.messages = [queued]
    writer.bots = [bot]
    writer.save()
    let record = NextMessageRecord(id: UUID(), anchorID: queued.id, kind: .turn, text: queued.content, state: .waiting)
    try writer.journal().put(record, kind: AppStore.nextMessageKind, id: record.id.uuidString)
    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("backup"))

    let recovering = AppStore(storeURL: url, autoStart: true, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(recovering.storeRestoreOffer != nil && recovering.turns.nextMessages.isEmpty)
    recovering.startLaunchWork(makeConnectivity: { nil })
    recovering.startTeamCoordination()
    #expect(!recovering.turns.didLaunchRecovery && recovering.teamPolling == nil)
    #expect(try await recovering.ensureTeam(recovering.herdrServers[0]) == false)
    #expect(try writer.journal().records(NextMessageRecord.self, kind: AppStore.nextMessageKind) == [record])
    #expect(recovering.restoreSetAsideStore())
    #expect(recovering.turns.nextMessages.map(\.id) == [record.id])
}

@Test @MainActor func onlyOneLiveWriterCanOpenTheSameStoreAndStaleWritesAreRefused() throws {
    let (url, defaults) = try setup()
    var gui: AppStore? = AppStore(storeURL: url, autoStart: false, exclusiveWriter: true, keyStore: InMemoryKeyStore(), defaults: defaults)
    gui?.bots = [Bot(name: "GUI")]
    gui?.save()
    let stale = launch(url, defaults)
    let command = AppStore(storeURL: url, autoStart: false, exclusiveWriter: true, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(!command.persistenceEnabled)
    let result = HeadlessCommands.importGrok(path: grokGoldenExport.path, store: command, output: { _ in })
    #expect(result != 0)
    gui = nil
    let next = AppStore(storeURL: url, autoStart: false, exclusiveWriter: true, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(next.persistenceEnabled)
    #expect(HeadlessCommands.importGrok(path: grokGoldenExport.path, store: next, output: { _ in }) == 0)
    let newer = try Data(contentsOf: url)
    stale.save()
    #expect(stale.turns.saveFailing)
    #expect(try Data(contentsOf: url) == newer)
}
