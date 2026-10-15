import Foundation
import SQLite3

/// P38 D: what the ledger offers its callers (a test can pass one that refuses every write).
@MainActor protocol RuntimeStoring: AnyObject {
    func put<T: Encodable>(_ value: T, kind: String, id: String) throws
    func putMany<T: Encodable>(_ values: [(id: String, value: T)], kind: String) throws
    func records<T: Decodable>(_ type: T.Type, kind: String) throws -> [T]
}

/// P38 D: `runtime.sqlite` next to store.json, a WAL journal for execution state that must survive a crash between two
/// saves: workflows, routine deliveries, sub-agent tasks and the saved-document index. Chats and settings stay in
/// store.json. Each record write and its event commit together; a failed write throws and the caller surfaces it.
@MainActor final class RuntimeLedger: RuntimeStoring {
    static let fileName = "runtime.sqlite"
    // Used on the main actor only until deinit; FULLMUTEX is a second guard.
    nonisolated(unsafe) private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw BackendError.unavailable("Could not open the execution journal.")
        }
        do {
            sqlite3_busy_timeout(database, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            let version = try statement("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) <= 1 else {
                throw BackendError.unavailable("The execution journal belongs to a newer \(AppConstants.name) version.")
            }
            try execute("CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))")
            try execute("CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, id TEXT NOT NULL, at REAL NOT NULL)")
            try execute("PRAGMA user_version=1")
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { if let database { sqlite3_close(database) } }

    func put<T: Encodable>(_ value: T, kind: String, id: String) throws {
        try putMany([(id: id, value: value)], kind: kind)
    }

    /// All or nothing: every value is encoded before the transaction opens, and any failed row rolls the batch back.
    func putMany<T: Encodable>(_ values: [(id: String, value: T)], kind: String) throws {
        let encoder = JSONEncoder()
        let payloads = try values.map { (id: $0.id, data: try encoder.encode($0.value)) }
        try execute("BEGIN IMMEDIATE")
        do {
            for payload in payloads { try write(payload.data, kind: kind, id: payload.id) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// In first-written order (an update keeps a record's place).
    func records<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        let row = try statement("SELECT payload FROM records WHERE kind=? ORDER BY rowid")
        defer { sqlite3_finalize(row) }
        sqlite3_bind_text(row, 1, kind, -1, transient)
        let decoder = JSONDecoder()
        var values: [T] = []
        while true {
            let code = sqlite3_step(row)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw failure() }
            let count = Int(sqlite3_column_bytes(row, 0))
            let data = count == 0 ? Data() : Data(bytes: sqlite3_column_blob(row, 0), count: count)
            values.append(try decoder.decode(type, from: data))
        }
    }

    /// The number of events written for `kind` (tests read the journal's history with it).
    func eventCount(kind: String) throws -> Int {
        let row = try statement("SELECT COUNT(*) FROM events WHERE kind=?")
        defer { sqlite3_finalize(row) }
        sqlite3_bind_text(row, 1, kind, -1, transient)
        guard sqlite3_step(row) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(row, 0))
    }

    private func write(_ data: Data, kind: String, id: String) throws {
        let row = try statement("INSERT INTO records(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(row) }
        sqlite3_bind_text(row, 1, kind, -1, transient); sqlite3_bind_text(row, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(row, 3, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(row) == SQLITE_DONE else { throw failure() }
        let event = try statement("INSERT INTO events(kind,id,at) VALUES(?,?,?)")
        defer { sqlite3_finalize(event) }
        sqlite3_bind_text(event, 1, kind, -1, transient); sqlite3_bind_text(event, 2, id, -1, transient)
        sqlite3_bind_double(event, 3, Date.now.timeIntervalSince1970)
        guard sqlite3_step(event) == SQLITE_DONE else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        return result
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> Error { BackendError.unavailable("The execution journal could not be saved or read (SQLite \(sqlite3_errcode(database))).") }
}

extension AppStore {
    /// The ledger, opened on first use. Not available in a window that does not save (demo, a store that failed to load).
    func journal() throws -> any RuntimeStoring {
        if let runtime { return runtime }
        guard persistenceEnabled else { throw BackendError.unavailable("The execution journal is not available in this window.") }
        let value = try RuntimeLedger(url: ledgerURL)
        runtime = value; return value
    }
    var ledgerURL: URL { fileURL.deletingLastPathComponent().appending(path: RuntimeLedger.fileName) }
    /// Launch restores read the ledger only when one was ever written, so a fresh store creates no file.
    var hasLedger: Bool { runtime != nil || FileManager.default.fileExists(atPath: ledgerURL.path) }

    /// Launch: what the ledger committed and store.json may have missed (a crash between the two saves).
    func restoreLedger() {
        restoreChildTasks(); restoreRoutineDeliveries(); restoreWorkflows()
    }
}
