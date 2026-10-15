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
}
