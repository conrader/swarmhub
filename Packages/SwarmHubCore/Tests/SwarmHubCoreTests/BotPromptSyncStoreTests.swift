import Foundation
import Testing
@testable import SwarmHubCore

private struct StubPromptTransport: BotPromptSyncTransport {
    var remote = BotPromptDocument()
    var fail = false
    var duringExchange: (@MainActor @Sendable () throws -> Void)?

    func exchange(_ document: BotPromptDocument) async throws -> BotPromptDocument {
        if fail { throw CoreError.interruptedStream }
        try await duringExchange?()
        var result = remote
        result.merge(document)
        return result
    }
}

private func promptSyncURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("prompts.json")
}

@MainActor @Test func promptSyncRelaunchKeepsOriginAndObservationsWithoutRevertingRemoteEdits() throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let local = BotPromptContext(name: "Scout", owner: "Mac owner")
    let mac = try BotPromptSyncStore(fileURL: url)
    try mac.observe(local, key: "k", now: 1)
    var phone = BotPromptSyncState()
    phone.edit(key: "k", origin: "phone", now: 100, fallback: local) { $0.owner = "Phone owner" }
    try mac.merge(phone.document)

    let reopened = try BotPromptSyncStore(fileURL: url)
    #expect(reopened.origin == mac.origin)
    #expect(reopened.state.observed["k"] == local)
    try reopened.observe(local, key: "k", now: 200)
    #expect(reopened.context(for: "k", fallback: local).owner == "Phone owner")
    var changed = local; changed.owner = "New Mac owner"
    try reopened.observe(changed, key: "k", now: 300)
    #expect(reopened.context(for: "k", fallback: local).owner == "New Mac owner")
    #expect(try BotPromptSyncStore(fileURL: url).state.document.bots["k"]?.owner?.at == 300)
}

@MainActor @Test func mobilePromptEditsPersistOnlyExplicitFieldsAndClearCoordinator() throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let phone = try BotPromptSyncStore(fileURL: url)
    let fallback = BotPromptContext(name: "Mobile default", coordinator: "Jarvis")
    try phone.edit(key: "k", now: 20, fallback: fallback) { $0.coordinator = nil }
    let reopened = try BotPromptSyncStore(fileURL: url)
    #expect(reopened.state.observed.isEmpty)
    #expect(reopened.state.document.bots["k"]?.name == nil)
    #expect(reopened.state.document.bots["k"]?.coordinator?.value == "")
    #expect(reopened.context(for: "k", fallback: fallback).coordinator == nil)
}

@MainActor @Test func failedPromptSaveDoesNotCommitMemory() throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let seed = try BotPromptSyncStore(fileURL: url)
    try seed.observe(BotPromptContext(name: "Scout"), key: "k", now: 0)
    let bytes = try Data(contentsOf: url)
    var writeAttempts = 0
    let store = try BotPromptSyncStore(fileURL: url, writeFile: { _, destination in
        #expect(destination == url)
        writeAttempts += 1
        throw CoreError.storage
    })
    let before = store.state
    #expect(throws: CoreError.storage) {
        try store.edit(key: "k", now: 1, fallback: BotPromptContext(name: "Scout")) { $0.owner = "changed" }
    }
    #expect(writeAttempts == 1)
    #expect(store.state == before)
    #expect(try Data(contentsOf: url) == bytes)
}

@MainActor @Test func corruptAndFuturePromptFilesArePreserved() throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    for text in ["broken json", "{\"origin\":\"device\",\"state\":{\"document\":{\"schema\":99,\"bots\":{}},\"observed\":{}}}"] {
        let bytes = Data(text.utf8)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { _ = try BotPromptSyncStore(fileURL: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }
}

@MainActor @Test func localPromptLoadDropsInvalidFields() throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let original = try BotPromptSyncStore(fileURL: url)
    try original.observe(BotPromptContext(name: "Scout"), key: "k", now: 1)
    var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var bad = BotPromptSyncState()
    var settings = BotPromptSettings()
    settings.owner = PromptStamp(value: "bad", at: -1, origin: "remote")
    bad.document.bots["k"] = settings
    saved["state"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bad))
    try JSONSerialization.data(withJSONObject: saved).write(to: url)
    let reopened = try BotPromptSyncStore(fileURL: url)
    #expect(reopened.state.document.bots["k"]?.owner == nil)
}

@MainActor @Test func saturatedUnicodeWinnerIsDurableEvenWhenSwiftStringsCompareEqual() throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try BotPromptSyncStore(fileURL: url)
    var remote = BotPromptDocument(), settings = BotPromptSettings()
    settings.owner = PromptStamp(value: "e\u{301}", at: .max, origin: "same")
    remote.bots["k"] = settings
    try store.merge(remote)
    settings.owner?.value = "é" // Greater UTF-8 bytes, although Swift String == considers these equal.
    remote.bots["k"] = settings
    try store.merge(remote)
    let reopened = try BotPromptSyncStore(fileURL: url)
    let value = try #require(reopened.state.document.bots["k"]?.owner?.value)
    #expect(Array(value.utf8) == Array("é".utf8))
}

@MainActor @Test func promptTransportMergesAndPersistsWithoutCopyingLocalObservations() async throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let phone = try BotPromptSyncStore(fileURL: url)
    var mac = BotPromptSyncState()
    let local = BotPromptContext(name: "Scout", owner: "Mac owner")
    mac.observe(local, key: "k", origin: "mac", now: 1)
    #expect(try await phone.synchronize(using: StubPromptTransport(remote: mac.document)))
    let reopened = try BotPromptSyncStore(fileURL: url)
    #expect(reopened.state.observed.isEmpty)
    #expect(reopened.context(for: "k", fallback: local).owner == "Mac owner")
}

@MainActor @Test func transportFailureKeepsDurableLocalPromptEdits() async throws {
    let url = promptSyncURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try BotPromptSyncStore(fileURL: url)
    try store.edit(key: "k", now: 1, fallback: BotPromptContext(name: "Scout")) { $0.owner = "kept" }
    let bytes = try Data(contentsOf: url)
    do {
        try await store.synchronize(using: StubPromptTransport(fail: true))
        Issue.record("Expected transport failure")
    } catch { #expect(error as? CoreError == .interruptedStream) }
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try BotPromptSyncStore(fileURL: url).state.document.bots["k"]?.owner?.value == "kept")
}

@MainActor @Test func editsDuringPromptExchangeSurviveItsStaleSnapshot() async throws {
    let store = try BotPromptSyncStore(fileURL: nil)
    let local = BotPromptContext(name: "Scout")
    try store.observe(local, key: "k", now: 1)
    let transport = StubPromptTransport(duringExchange: {
        try store.edit(key: "k", now: 200, fallback: local) { $0.owner = "during exchange" }
    })
    try await store.synchronize(using: transport)
    #expect(store.context(for: "k", fallback: local).owner == "during exchange")
}

@MainActor @Test func futurePromptDocumentDoesNotWriteLocalStorage() throws {
    let url = promptSyncURL()
    let store = try BotPromptSyncStore(fileURL: url)
    var future = BotPromptDocument(); future.schema = 99
    #expect(try !store.merge(future))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
