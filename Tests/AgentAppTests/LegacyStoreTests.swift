import Foundation
import Testing
@testable import AgentApp

// A store an older build wrote also holds bots of two backends this build no longer has. They are not loaded: the
// file is copied as it was to a dated backup beside it, then saved without them. Bots on Herdr are not touched.
// Fixtures: Tests/Fixtures/legacy_store_with_removed_backends.json (three removed bots, two Herdr bots, a group they
// share and a group of removed bots only, plus every top-level key older builds wrote) and
// legacy_store_only_removed_backends.json.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)
private let atlasID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private let codexID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
private let jarvisID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let sharedGroupID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

/// A fresh folder holding `fixture` as store.json; returns the store's URL and the fixture's bytes.
private func legacyStore(_ fixture: String = "legacy_store_with_removed_backends.json") throws -> (url: URL, original: Data) {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = try Data(contentsOf: fixtures.appending(path: fixture))
    try original.write(to: url)
    return (url, original)
}

@MainActor private func open(_ url: URL, defaults: UserDefaults) -> AppStore {
    AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
}

private func backups(beside store: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: store.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.contains(LegacyStore.backupMarker) }.sorted { $0.path < $1.path }
}

@Test func aLegacyStoreDecodesWithItsRemovedBotsLeftOut() throws {
    let file = try StoreFile.decode(try Data(contentsOf: fixtures.appending(path: "legacy_store_with_removed_backends.json")))
    #expect(file.bots.map(\.name) == ["Atlas", "Codex"], "the bots on Herdr load")
    #expect(file.removedBots.map(\.name) == ["Jarvis", "Infra", "Claw"])
    #expect(file.removedBots.map(\.backend) == ["Hermes Agent", "Hermes Agent", "OpenClaw"])
    #expect(file.removedBots.first?.id == jarvisID)
    #expect(file.groups.count == 2, "groups load as written; the store drops what belonged to removed bots")
}

@Test func aBotOfABackendNoBuildKnowsIsStillADecodeError() {
    let json = #"{"version":2,"bots":[{"id":"99999999-9999-4999-8999-999999999999","name":"Later","persona":"p","backend":"Something Newer","unreadCount":0,"createdAt":1,"messages":[]}],"groups":[]}"#
    #expect(throws: (any Error).self) { try StoreFile.decode(Data(json.utf8)) }
}

@Test func aVersionOneStoreLeavesItsRemovedBotsOutToo() throws {
    let json = #"[{"id":"99999999-9999-4999-8999-999999999999","name":"Old","persona":"p","backend":"Hermes Agent","unreadCount":0,"createdAt":1,"messages":[]},{"id":"88888888-8888-4888-8888-888888888888","name":"Kept","persona":"p","backend":"Herdr","unreadCount":0,"createdAt":1,"messages":[]}]"#
    let file = try StoreFile.decode(Data(json.utf8))
    #expect(file.version == 1 && file.bots.map(\.name) == ["Kept"] && file.removedBots.map(\.name) == ["Old"])
}

@MainActor @Test func openingALegacyStoreBacksItUpThenRemovesTheOldBots() throws {
    let (url, original) = try legacyStore()
    let defaults = isolatedDefaults()
    let store = open(url, defaults: defaults)

    // The backup is the file exactly as it was.
    let saved = try backups(beside: url)
    #expect(saved.count == 1)
    #expect(try Data(contentsOf: #require(saved.first)) == original, "byte for byte")

    // The Herdr bots are untouched: id, name, avatar, instructions, role and chat.
    #expect(store.bots.map(\.id) == [atlasID, codexID])
    let atlas = try #require(store.bots.first)
    #expect(atlas.name == "Atlas" && atlas.title == "Claude Code on Herdr" && atlas.persona == "You plan launches." && atlas.backend == .herdr)
    #expect(atlas.avatarName == .faceSun && atlas.avatarMark == AvatarMark(shape: "robot", colour: "teal") && atlas.canManageBots && atlas.unreadCount == 1)
    #expect(atlas.messages.map(\.content) == ["Plan the launch", "Here is the plan.", "A card from an older build"])
    #expect(atlas.messages[1].activity?.steps.first?.name == "bash", "a step's fields this build does not know are ignored")
    #expect(atlas.messages[2].presentation == .text, "a card of an older build reads as text")
    #expect(store.bots[1].sessionID == "kept-session", "the session id is read from the name it was saved under before")

    // What only belonged to the removed bots is gone; a shared group keeps its other members and its transcript.
    #expect(store.groups.map(\.id) == [sharedGroupID], "the group of removed bots only went with them")
    let group = try #require(store.groups.first)
    #expect(group.memberIDs == [atlasID, codexID])
    #expect(group.messages.map(\.content) == ["Everyone: status", "From Jarvis", "From Atlas"], "what a removed bot said in a shared group stays")

    // One plain line, until dismissed.
    let notice = try #require(store.legacyNotice)
    #expect(notice.contains("3 bots from the older version were removed") && notice.contains(saved[0].lastPathComponent))
    #expect(store.errorMessage == nil && store.persistenceEnabled)

    // The saved store holds no removed bot and none of the older builds' keys.
    let written = try String(contentsOf: url, encoding: .utf8)
    for gone in ["Hermes Agent", "OpenClaw", "hermesProfile", "boxReadings", "heartbeat", "approvalRoutes", "\"name\":\"Jarvis\"", "aFieldNoBuildEverHad"] {
        #expect(!written.contains(gone), "store.json still holds \(gone)")
    }
    let again = try StoreFile.decode(Data(written.utf8))
    #expect(again.removedBots.isEmpty && again.bots.map(\.id) == [atlasID, codexID])
}

@MainActor @Test func aSecondLaunchMakesNoSecondBackupAndTheLineStaysUntilDismissed() throws {
    let (url, original) = try legacyStore()
    let defaults = isolatedDefaults()
    let first = open(url, defaults: defaults)
    let notice = try #require(first.legacyNotice)

    let second = open(url, defaults: defaults)
    #expect(try backups(beside: url).count == 1, "nothing is left to remove, so nothing is backed up again")
    #expect(try Data(contentsOf: #require(try backups(beside: url).first)) == original, "the backup is never written over")
    #expect(second.bots.map(\.id) == [atlasID, codexID])
    #expect(second.legacyNotice == notice, "the line is shown again until it is dismissed")

    second.dismissLegacyNotice()
    #expect(second.legacyNotice == nil)
    #expect(open(url, defaults: defaults).legacyNotice == nil, "dismissed for good")
    #expect(try backups(beside: url).count == 1, "dismissing the line never touches the backup")
}

@MainActor @Test func aStoreOfOnlyRemovedBotsEndsEmptyAndTheWizardOpens() throws {
    let (url, original) = try legacyStore("legacy_store_only_removed_backends.json")
    let defaults = isolatedDefaults()
    let store = open(url, defaults: defaults)
    #expect(store.bots.isEmpty && store.groups.isEmpty && store.selectedBot == nil)
    #expect(try Data(contentsOf: #require(try backups(beside: url).first)) == original)
    #expect(store.legacyNotice?.contains("2 bots from the older version were removed") == true)
    #expect(store.storeRestoreOffer == nil, "the backup is not offered back: this build would leave its bots out again")
    #expect(FirstRun.needsWizard(defaults: defaults, bots: store.bots), "no bot at all: the setup wizard opens")
}

@MainActor @Test func withoutABackupNothingIsWritten() throws {
    let (url, original) = try legacyStore()
    let folder = url.deletingLastPathComponent()
    // The folder cannot take a new file, so the backup cannot be made.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    let store = open(url, defaults: isolatedDefaults())
    #expect(store.errorMessage == LegacyStore.backupFailed)
    #expect(!store.persistenceEnabled, "saving is off for this launch")
    store.save()
    #expect(try Data(contentsOf: url) == original, "the store is left exactly as it was")
    #expect(store.legacyNotice == nil)
}

@Test func theBackupNameIsDatedAndNeverTaken() throws {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_794_870_605)
    let first = try LegacyStore.writeBackup(Data("one".utf8), store: url, now: now)
    let second = try LegacyStore.writeBackup(Data("two".utf8), store: url, now: now)
    #expect(first.lastPathComponent.hasPrefix("store.json.before-herdr-only-2026-11-1"))
    #expect(second.lastPathComponent == first.lastPathComponent + "-2", "the same moment gets its own name")
    #expect(try Data(contentsOf: first) == Data("one".utf8), "an existing backup is never written over")
    #expect(LegacyStore.notice(removed: 1, backup: first).hasPrefix("1 bot from the older version was removed"))
}

/// `--render-snapshot` opens the store read only: the old bots are left out of the picture and nothing is written.
@MainActor @Test func aReadOnlyStoreLeavesALegacyStoreExactlyAsItIs() throws {
    let (url, original) = try legacyStore()
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: url, autoStart: false, readOnly: true, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(store.bots.map(\.id) == [atlasID, codexID] && !store.persistenceEnabled)
    store.save()
    let kept = try backups(beside: url)
    #expect(try Data(contentsOf: url) == original && kept.isEmpty)
    #expect(store.legacyNotice == nil && defaults.string(forKey: LegacyStore.noticeKey) == nil && defaults.object(forKey: AppStore.samplesMigrationKey) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["store.json"], "no file beside it")
}

/// A store an older build wrote with Herdr bots only still holds what this build does not keep with a bot (its
/// threads, routines, approvals). Nothing is removed and nothing is said, but the file is kept as it was, once.
@MainActor @Test func anOlderStoreOfHerdrBotsIsBackedUpOnceAndSaysNothing() throws {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appending(path: "legacy_store_with_removed_backends.json"))) as! [String: Any]
    json["bots"] = (json["bots"] as! [[String: Any]]).filter { $0["backend"] as? String == "Herdr" }
    json["groups"] = []
    let original = try JSONSerialization.data(withJSONObject: json)
    try original.write(to: url)
    let decoded = try StoreFile.decode(original)
    #expect(decoded.isOlder && decoded.removedBots.isEmpty)

    let defaults = isolatedDefaults()
    let store = open(url, defaults: defaults)
    #expect(store.bots.map(\.id) == [atlasID, codexID] && store.legacyNotice == nil && store.errorMessage == nil)
    #expect(try Data(contentsOf: #require(try backups(beside: url).first)) == original, "the file as the older build left it")
    let rewritten = try StoreFile.decode(Data(contentsOf: url))
    #expect(!rewritten.isOlder && rewritten.bots.map(\.id) == [atlasID, codexID], "saved at once as this build keeps it")
    _ = open(url, defaults: defaults)
    #expect(try backups(beside: url).count == 1, "the next launch has nothing to back up")
}

@MainActor @Test func aStoreThisBuildWroteIsNeverBackedUp() throws {
    let url = temporaryStore(), defaults = isolatedDefaults()
    let first = open(url, defaults: defaults)
    first.addBot(name: "Ada", persona: "You help.", backend: .herdr, avatarName: nil)
    first.createGroup(name: "Pair", memberIDs: [first.bots[0].id, first.bots[0].id])
    let written = try Data(contentsOf: url)
    let decoded = try StoreFile.decode(written)
    #expect(!decoded.isOlder)
    let second = open(url, defaults: defaults)
    let kept = try backups(beside: url)
    #expect(second.bots.map(\.name) == ["Ada"] && kept.isEmpty && second.legacyNotice == nil)
    #expect(try Data(contentsOf: url) == written, "opening it writes nothing")
}
