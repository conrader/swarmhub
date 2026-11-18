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
    #expect(StoreRestoreCopy.question(offer).contains("3 bots") && StoreRestoreCopy.restore(offer) == "Restore my 3 bots")
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
    #expect(StoreRestore.offer(directory: directory, store: url, current: [], limit: 8) == nil)
    #expect(StoreRestore.offer(directory: directory, store: url, current: [], limit: 9)?.url.lastPathComponent == "store.json.backup-old")
    #expect(StoreRestore.offer(directory: directory, store: url, current: [], maxBytes: 64) == nil)
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
    #expect(store.bots.isEmpty && !store.persistenceEnabled)
    #expect(store.unreadableStoreSetAside && store.storeRestoreOffer == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let directory = url.deletingLastPathComponent()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let preserved = try #require(files.first { $0.lastPathComponent.hasPrefix("store.json.corrupt-") })
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

@Test @MainActor func aMixedStoreLoadsHerdrBotsAndOffersThemFromASetAsideCopy() throws {
    let (url, defaults) = try setup()
    let current = Bot(name: "Current", backend: .herdr, sessionID: "session-1")
    let hermesID = UUID()
    let group = GroupChat(name: "Team", memberIDs: [current.id, hermesID])
    let data = try JSONEncoder().encode(StoreFile(bots: [current], groups: [group]))
    var mixed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let bots = try #require(mixed["bots"] as? [[String: Any]]) + [
        ["backend": "Hermes Agent", "id": hermesID.uuidString],
        ["backend": "OpenClaw", "id": UUID().uuidString],
    ]
    mixed["bots"] = bots
    let original = try JSONSerialization.data(withJSONObject: mixed)
    let versionOne = try StoreFile.decode(JSONSerialization.data(withJSONObject: bots))
    #expect(versionOne.version == 1 && versionOne.bots.map(\.id) == [current.id])

    try original.write(to: url)
    let loaded = launch(url, defaults)
    #expect(loaded.persistenceEnabled && loaded.storeRestoreOffer == nil)
    #expect(loaded.bots.map(\.id) == [current.id] && loaded.bots.first?.sessionID == "session-1")
    #expect(loaded.groups.first?.memberIDs == [current.id])

    let backup = url.appendingPathExtension("corrupt-fixture")
    try FileManager.default.moveItem(at: url, to: backup)
    mixed["bots"] = Array(bots.dropFirst())
    try JSONSerialization.data(withJSONObject: mixed).write(to: url)
    let store = launch(url, defaults)
    #expect(store.persistenceEnabled && store.bots.isEmpty)
    #expect(store.storeRestoreOffer?.botNames == ["Current"])
    #expect(store.restoreSetAsideStore())
    #expect(store.bots.map(\.id) == [current.id] && store.groups.first?.memberIDs == [current.id])
    #expect(try Data(contentsOf: backup) == original)
}
