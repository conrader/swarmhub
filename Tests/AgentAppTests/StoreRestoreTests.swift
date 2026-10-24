import Foundation
import Testing
@testable import AgentApp

// autoctx1: a store.json set aside as unreadable (`store.json.corrupt-*`) or a backup next to it is offered back in a
// chat-style prompt; SwarmHub never seeds its default 127.0.0.1 bot over it. Temporary directories only.

/// A configured Hermes (so a fresh launch would seed "Hermes"), and a store directory that does not exist yet.
private func setup() throws -> (url: URL, defaults: UserDefaults) {
    let defaults = isolatedDefaults(); defaults.set("http://127.0.0.1:8642/v1", forKey: "hermesBaseURL")
    let url = temporaryStore(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (url, defaults)
}

/// Writes a real store with `names` (the way SwarmHub saves one) at `file` beside `store`.
@MainActor private func writeStore(_ names: [String], as file: String, beside store: URL, modified: Date? = nil) throws -> URL {
    let scratch = temporaryStore()
    try FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = AppStore(storeURL: scratch, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    writer.bots = names.map { Bot(name: $0, backend: .hermes, hermesProfile: $0.lowercased()) }
    writer.bots.forEach { $0.hermesBaseURL = "https://box.example.com/v1" }
    writer.save()
    let target = store.deletingLastPathComponent().appending(path: file)
    try FileManager.default.moveItem(at: scratch, to: target)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path) }
    return target
}

@MainActor private func launch(_ url: URL, _ defaults: UserDefaults) -> AppStore {
    AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
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

@Test @MainActor func withNothingToRestoreTheDefaultBotIsSeededAsBefore() throws {
    let (url, defaults) = try setup()
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer == nil)
    #expect(store.bots.map(\.name) == ["Hermes"])
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

@Test @MainActor func restoreLoadsTheSetAsideStoreAndKeepsTheCopy() throws {
    let (url, defaults) = try setup()
    let corrupt = try writeStore(["Boppy", "Jarvis"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    let store = launch(url, defaults)
    #expect(store.restoreSetAsideStore())
    #expect(store.storeRestoreOffer == nil && store.storeRestoreNote == StoreRestoreCopy.restored(2))
    #expect(Set(store.bots.map(\.name)) == ["Boppy", "Jarvis"])
    #expect(store.bots.allSatisfy { $0.hermesBaseURL == "https://box.example.com/v1" })
    // Saved as store.json, and the next launch opens it without asking again.
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
    let next = launch(url, defaults)
    #expect(Set(next.bots.map(\.name)) == ["Boppy", "Jarvis"] && next.storeRestoreOffer == nil)
}

@Test @MainActor func aStoreHoldingOnlyTheSeededBotIsOfferedTheSetAsideOne() throws {
    let (url, defaults) = try setup()
    // What 0.6.6 left behind (botloss1): a fresh store seeded with one default bot, and the set-aside copy beside it.
    let seeded = launch(url, defaults)
    #expect(seeded.bots.map(\.name) == ["Hermes"] && FileManager.default.fileExists(atPath: url.path))
    _ = try writeStore(["Boppy", "Jarvis", "Swarmhub"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    // Next launch: store.json holds only the seed, so the copy is offered; restoring moves the seed aside.
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer?.botCount == 3)
    #expect(store.restoreSetAsideStore())
    #expect(store.bots.count == 3)
    let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(names.contains { $0.hasPrefix("store.json.before-restore-") })
}

@Test @MainActor func startFreshSeedsTheDefaultBotAndKeepsTheCorruptCopy() throws {
    let (url, defaults) = try setup()
    let corrupt = try writeStore(["Boppy"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer != nil && store.bots.isEmpty)
    store.declineStoreRestore()
    #expect(store.storeRestoreOffer == nil && store.bots.map(\.name) == ["Hermes"])
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
    // Answered once: the next launch opens the seeded store without asking again.
    #expect(launch(url, defaults).storeRestoreOffer == nil)
}

@Test @MainActor func aStoreWithRealBotsIsNeverOfferedAnything() throws {
    let (url, defaults) = try setup()
    _ = try writeStore(["Boppy", "Jarvis"], as: "store.json.corrupt-2026-10-23T04-45-18Z", beside: url)
    _ = try writeStore(["Mine"], as: "store.json", beside: url)
    let store = launch(url, defaults)
    #expect(store.storeRestoreOffer == nil && store.bots.map(\.name) == ["Mine"])
}
