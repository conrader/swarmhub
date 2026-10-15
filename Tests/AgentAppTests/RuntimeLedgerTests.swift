import Foundation
import SQLite3
import Testing
@testable import AgentApp

/// A journal that refuses every write, like a full disk.
@MainActor final class RejectingRuntime: RuntimeStoring {
    func put<T: Encodable>(_ value: T, kind: String, id: String) throws { throw BackendError.unavailable("fixture disk-full") }
    func putMany<T: Encodable>(_ values: [(id: String, value: T)], kind: String) throws { throw BackendError.unavailable("fixture disk-full") }
    func records<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] { [] }
}

@MainActor struct RuntimeLedgerTests {
    struct Record: Codable, Equatable { let value: Double }
    func ledgerURL() -> URL { temporaryStore().deletingLastPathComponent().appending(path: RuntimeLedger.fileName) }

    @Test func recordsRoundTripInFirstWrittenOrderAcrossReopen() throws {
        let url = ledgerURL()
        do {
            let ledger = try RuntimeLedger(url: url)
            try ledger.put(Record(value: 1), kind: "fixture", id: "one")
            try ledger.put(Record(value: 2), kind: "fixture", id: "two")
            try ledger.put(Record(value: 3), kind: "fixture", id: "one")
            try ledger.put(Record(value: 9), kind: "other", id: "one")
            #expect(try ledger.eventCount(kind: "fixture") == 3)
        }
        let reopened = try RuntimeLedger(url: url)
        #expect(try reopened.records(Record.self, kind: "fixture") == [.init(value: 3), .init(value: 2)])
        #expect(try reopened.records(Record.self, kind: "other") == [.init(value: 9)])
        #expect(try reopened.records(Record.self, kind: "missing").isEmpty)
    }

    @Test func encodingFailureLeavesAtomicBatchUnchanged() throws {
        let ledger = try RuntimeLedger(url: ledgerURL())
        try ledger.put(Record(value: 1), kind: "fixture", id: "one")
        #expect(throws: (any Error).self) { try ledger.putMany([("one", Record(value: 2)), ("two", Record(value: .infinity))], kind: "fixture") }
        #expect(try ledger.records(Record.self, kind: "fixture") == [.init(value: 1)])
        #expect(try ledger.eventCount(kind: "fixture") == 1)
    }

    @Test func journalFromANewerVersionIsRefused() throws {
        let url = ledgerURL()
        _ = try RuntimeLedger(url: url)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version=2", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(throws: (any Error).self) { _ = try RuntimeLedger(url: url) }
    }

    @Test func storeOpensTheLedgerBesideStoreJSONOnlyWhenUsed() throws {
        let url = temporaryStore()
        let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(!store.hasLedger)
        try store.journal().put(Record(value: 4), kind: "fixture", id: "a")
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: "runtime.sqlite").path))
        let demo = AppStore(demoMode: true, storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(throws: (any Error).self) { _ = try demo.journal() }
    }

    @Test func artifactIndexMovesIntoTheLedgerOnceAndKeepsAccess() throws {
        let url = temporaryStore(), directory = url.deletingLastPathComponent().appending(path: "artifacts")
        let reader = UUID(), other = UUID()
        let old = try RuntimeArtifacts(directory: directory).save(Data("Evidence".utf8), name: "Evidence", mimeType: "text/plain", owners: [reader])
        let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(try store.artifacts().records().map(\.id) == [old.id])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "index.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "index.json.imported").path))
        #expect(String(decoding: try store.artifacts().read(old.id, botID: reader), as: UTF8.self) == "Evidence")
        #expect(throws: (any Error).self) { try store.artifacts().read(old.id, botID: other) }
        let added = try store.artifacts().save(Data("More".utf8), name: "More", mimeType: "text/plain", owners: [other])
        let reopened = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(try reopened.artifacts().records().map(\.id) == [old.id, added.id])
    }

    @Test func artifactFailureCleansUncommittedBytes() throws {
        let directory = temporaryStore().deletingLastPathComponent().appending(path: "artifacts")
        let artifacts = RuntimeArtifacts(directory: directory, ledger: RejectingRuntime())
        #expect(throws: (any Error).self) { try artifacts.save(Data("Evidence".utf8), name: "Evidence", mimeType: "text/plain", owners: [UUID()]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
