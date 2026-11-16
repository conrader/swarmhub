import Foundation
import Testing
@testable import AgentApp

private let bundles = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/bundles").standardizedFileURL
private let exportFolder = bundles.appending(path: "export")
private let jarvisID = "00000000-0000-4000-8000-000000000001"

@MainActor private func grokStore(_ url: URL = temporaryStore(), keys: [String: String] = [:]) -> (AppStore, InMemoryKeyStore) {
    let keyStore = InMemoryKeyStore(keys)
    return (AppStore(storeURL: url, autoStart: false, keyStore: keyStore, defaults: isolatedDefaults()), keyStore)
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
    #expect(jarvis.messages.isEmpty) // never part of the live conversation sent to the agent
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

/// P15: the map returns the effective mark (stored words when valid, case-sensitive, else derived from the id).
@Test func grokAvatarMapKeepsValidWordsAndDerivesTheRest() {
    for shape in ["blob", "cylinder", "shield", "gem", "hex", "leaf", "star"] {
        #expect(GrokAvatarMap.map(shape: shape, colour: "green", sourceID: "x") == AvatarMark(shape: shape, colour: "green"))
    }
    let derived = GrokDefaultLook.mark(for: "x")
    #expect(GrokAvatarMap.map(shape: nil, colour: "violet", sourceID: "x") == AvatarMark(shape: derived.shape, colour: "violet"))
    #expect(GrokAvatarMap.map(shape: "star", colour: "pink", sourceID: "x") == AvatarMark(shape: "star", colour: derived.colour))
    #expect(GrokAvatarMap.map(shape: "Blob", colour: "Black", sourceID: "x") == derived)
    #expect(GrokAvatarMap.map(shape: nil, colour: nil, sourceID: jarvisID) == GrokDefaultLook.mark(for: jarvisID))
    #expect(Set(GrokAvatarMap.accents.keys) == Set(GrokAvatarMap.colourFaces.keys))
}

@MainActor @Test func headlessGrokImportPrintsCountsOnly() throws {
    let (store, _) = grokStore()
    var lines: [String] = []
    #expect(HeadlessCommands.importGrok(path: exportFolder.path, store: store, output: { lines.append($0) }) == 0)
    #expect(lines.contains { $0.hasPrefix("Jarvis | bot | history 9 | avatar blob/black -> blob") })
    #expect(!lines.joined().contains("synthetic"))
    lines = []
    #expect(HeadlessCommands.importGrok(path: bundles.appending(path: "unknown-format.json").path, store: store, output: { lines.append($0) }) == 2)
}

