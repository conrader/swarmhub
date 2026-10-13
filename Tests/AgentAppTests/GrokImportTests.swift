import Foundation
import Testing
@testable import AgentApp

private let bundles = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/bundles").standardizedFileURL
private let exportFolder = bundles.appending(path: "export")
private let jarvisID = "00000000-0000-4000-8000-000000000001"

@MainActor private func grokStore(_ url: URL = temporaryStore(), keys: [String: String] = [:]) -> (AppStore, InMemoryKeyStore) {
    let keyStore = InMemoryKeyStore(keys)
    return (AppStore(storeURL: url, autoConfigureHermes: false, keyStore: keyStore, defaults: isolatedDefaults()), keyStore)
}

@MainActor @Test func grokImportMapsBotsProfilesAvatarsAndGroup() throws {
    let (store, _) = grokStore()
    let rows = try store.importGrokExport(at: exportFolder)
    #expect(rows.count == 4)
    let jarvis = try #require(store.bots.first { $0.grokSourceID == jarvisID })
    #expect(jarvis.name == "Jarvis" && jarvis.backend == .hermes && jarvis.hermesProfile == "grok-jarvis")
    #expect(jarvis.hermesBaseURL == "https://konrad.agenthut.net/v1")
    #expect(jarvis.avatarName == .blob && jarvis.accentColor == GrokAvatarMap.accents["black"])
    #expect(jarvis.persona.contains("[REDACTED]") && !jarvis.persona.contains("FAKEFAKE"))
    #expect(jarvis.grokHistoryCount == 9) // 8 messages + 1 rename line
    #expect(jarvis.messages.isEmpty)
    let finance = try #require(store.bots.first { $0.name == "Finance Controller" })
    #expect(finance.hermesProfile == "grok-finance-controller" && finance.avatarName == .planet)
    let plain = try #require(store.bots.first { $0.name == "Plain Bot" })
    let group = try #require(store.groups.first { $0.name == "Konrad, Jarvis, Plain Bot" })
    #expect(group.memberIDs == [jarvis.id, plain.id] && group.grokHistoryCount == 3 && store.grokHistory.messages(for: group.id).count == 3)
    #expect(!store.bots.contains { $0.isReadOnlyArchive || $0.name == group.name })
    #expect(store.bots.filter { $0.isDemo && !$0.isHidden }.isEmpty)
}

@MainActor @Test func grokHistoryIsLazyAndOutsideStoreJSON() throws {
    let url = temporaryStore()
    let (store, _) = grokStore(url)
    try store.importGrokExport(at: exportFolder)
    let storeText = try String(contentsOf: url, encoding: .utf8)
    #expect(!storeText.contains("Hello Jarvis") && !storeText.contains("Ledger checked"))

    let (reopened, _) = grokStore(url)
    let jarvis = try #require(reopened.bots.first { $0.grokSourceID == jarvisID })
    #expect(!reopened.grokHistory.isLoaded(jarvis.id))
    let history = reopened.grokHistory.messages(for: jarvis.id)
    #expect(reopened.grokHistory.isLoaded(jarvis.id))
    #expect(history.count == 9 && history.map(\.seq) == history.map(\.seq).sorted())
    #expect(history.contains { $0.role == "system" && $0.channel == "event" && $0.text.contains("Jarv") })
    #expect(history.filter(\.hidden).map(\.id) == ["j10"])
    #expect(history.first { $0.id == "j3" }?.to == "Finance Controller")
    #expect(history.filter { $0.matches("ledger") }.count == 2)
    let attributes = try FileManager.default.attributesOfItem(atPath: reopened.grokHistory.fileURL(for: jarvis.id).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(jarvis.messages.isEmpty) // never part of the live conversation sent to Hermes
}

@MainActor @Test func grokReimportIsIdempotentAndMergesNewLines() throws {
    let (store, _) = grokStore()
    try store.importGrokExport(at: exportFolder)
    let botCount = store.bots.count
    let rows = try store.importGrokExport(at: exportFolder)
    #expect(store.bots.count == botCount && rows.allSatisfy { !$0.created })
    var bundle = try #require(try GrokBundleLoader.load(from: exportFolder).first { $0.sourceId == jarvisID })
    bundle.messages.append(.init(id: "j99", seq: 99, role: "user", author: nil, text: "new synthetic line", timestamp: nil, hidden: false, channel: "chat", to: nil))
    try store.importGrokBundles([bundle])
    let jarvis = try #require(store.bots.first { $0.grokSourceID == jarvisID })
    #expect(jarvis.grokHistoryCount == 10 && store.grokHistory.messages(for: jarvis.id).count == 10)
    #expect(store.bots.count == botCount)
}

@MainActor @Test func grokImportAdoptsExistingProfileBot() throws {
    let (store, _) = grokStore()
    let existing = Bot(name: "grok-jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    store.bots.append(existing)
    try store.importGrokExport(at: exportFolder)
    #expect(store.bots.filter { $0.hermesProfile == "grok-jarvis" }.count == 1)
    #expect(existing.grokSourceID == jarvisID && existing.name == "Jarvis")
}

@Test func grokBundleLoaderAcceptsSingleBundleAndRejectsUnknownFormat() throws {
    let single = try GrokBundleLoader.load(from: bundles.appending(path: "single-bundle.json"))
    #expect(single.map(\.name) == ["Finance Controller"])
    #expect(throws: GrokBundleError.unsupportedFormat("agentapp-bot-bundle/v9")) { try GrokBundleLoader.load(from: bundles.appending(path: "unknown-format.json")) }
    let folder = FileManager.default.temporaryDirectory.appending(path: "grok-index-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"format":"agentapp-bot-bundle/v2","bots":[]}"#.utf8).write(to: folder.appending(path: "index.json"))
    #expect(throws: GrokBundleError.unsupportedFormat("agentapp-bot-bundle/v2")) { try GrokBundleLoader.load(from: folder) }
    try Data(#"{"format":"agentapp-bot-bundle/v1","bots":[{"bundle":"../outside.json"}]}"#.utf8).write(to: folder.appending(path: "index.json"))
    #expect(throws: GrokBundleError.unsafePath("../outside.json")) { try GrokBundleLoader.load(from: folder) }
}

@Test func grokAvatarTableUsesOwnAssets() {
    for (shape, expected) in [("blob", BotAvatarName.blob), ("cylinder", .coffee), ("shield", .robot), ("gem", .planet), ("hex", .bubble), ("leaf", .pebble)] {
        #expect(GrokAvatarMap.map(shape: shape, colour: "green", sourceID: "x").avatar == expected)
    }
    #expect(GrokAvatarMap.map(shape: nil, colour: "violet", sourceID: "x") == (.faceLilac, "#8E6CD8"))
    #expect(GrokAvatarMap.map(shape: "star", colour: "pink", sourceID: "x").accent == nil)
    let fallback = GrokAvatarMap.map(shape: nil, colour: nil, sourceID: jarvisID)
    #expect(fallback.avatar.isFlatFace && fallback == GrokAvatarMap.map(shape: nil, colour: nil, sourceID: jarvisID))
    #expect(Set(GrokAvatarMap.accents.keys) == Set(GrokAvatarMap.colourFaces.keys))
}

@MainActor @Test func missingKeyShowsAddKeyStateInsteadOfErrors() throws {
    let (store, keys) = grokStore()
    try store.importGrokExport(at: exportFolder)
    let jarvis = try #require(store.bots.first { $0.grokSourceID == jarvisID })
    store.selectedBot = jarvis
    #expect(store.needsKey(jarvis))
    #expect(store.send(text: "hi") == false && store.errorMessage == nil && jarvis.messages.isEmpty)
    store.saveKey("synthetic-key", for: jarvis)
    #expect(keys.key(for: "hermes.grok-jarvis") == "synthetic-key" && !store.needsKey(jarvis))
}

@MainActor @Test func headlessGrokImportPrintsCountsOnly() throws {
    let (store, _) = grokStore()
    var lines: [String] = []
    #expect(HeadlessCommands.importGrok(path: exportFolder.path, store: store, output: { lines.append($0) }) == 0)
    #expect(lines.contains { $0.hasPrefix("Jarvis | grok-jarvis | history 9 | avatar blob/black -> blob") })
    #expect(!lines.joined().contains("synthetic"))
    lines = []
    #expect(HeadlessCommands.importGrok(path: bundles.appending(path: "unknown-format.json").path, store: store, output: { lines.append($0) }) == 2)
}

@MainActor @Test func keyFileImportChecksPermissionsThenShreds() throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString).txt").path
    try "default=key-default\ngrok-jarvis=key=with=equals\n# note\nbad line\n".write(toFile: path, atomically: true, encoding: .utf8)
    let keys = InMemoryKeyStore()
    var lines: [String] = []
    chmod(path, 0o644)
    #expect(HeadlessCommands.importKeys(path: path, keyStore: keys, output: { lines.append($0) }) == 2)
    #expect(FileManager.default.fileExists(atPath: path) && keys.all().isEmpty)
    #expect(HeadlessCommands.checkKeyFile(path) == .wrongMode(0o644))
    chmod(path, 0o600)
    lines = []
    #expect(HeadlessCommands.importKeys(path: path, keyStore: keys, output: { lines.append($0) }) == 1) // the bad line fails
    #expect(keys.key(for: "hermes") == "key-default" && keys.key(for: "hermes.grok-jarvis") == "key=with=equals")
    #expect(lines.contains("default: OK") && lines.contains("grok-jarvis: OK") && lines.contains("line 4: failed (expected profile=key)"))
    #expect(!lines.joined().contains("key-default") && !lines.joined().contains("with=equals"))
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(HeadlessCommands.checkKeyFile(path) == .missing)
}

@MainActor @Test func legacyStoreWithOldRoutinesLoadsAndAcceptsGrokImport() throws {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: bundles.appending(path: "../legacy_store_routines_without_prompt.json").standardizedFileURL, to: url)
    let (store, _) = grokStore(url)
    #expect(store.persistenceEnabled && store.errorMessage == nil)
    let routine = try #require(store.bots.first?.routines.first)
    #expect(routine.name == "Morning" && routine.prompt.isEmpty && routine.lastRun == "Never" && routine.importKind == .local)
    try store.importGrokExport(at: exportFolder)
    #expect(store.bots.count == 4 && store.groups.count == 1)
}
