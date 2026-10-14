import Foundation
import CSQLite

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

/// Actor-serialized, transactional cache; credentials are never accepted by this API.
public actor SQLiteRepository {
    private let handle: SQLiteHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw CoreError.storage
        }
        handle = SQLiteHandle(db)
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw CoreError.storage }
    }

    public func profiles() throws -> [AgentProfile] { try read("profiles", as: [AgentProfile].self) ?? [] }
    public func saveProfiles(_ profiles: [AgentProfile]) throws { try write("profiles", value: profiles) }
    public func cache(agentID: String) throws -> ChatCache { try read("chat:\(agentID)", as: ChatCache.self) ?? ChatCache() }
    public func saveCache(_ cache: ChatCache, agentID: String) throws { try write("chat:\(agentID)", value: cache) }
    public func remove(agentID: String) throws {
        let profiles = try profiles().filter { $0.id != agentID }
        guard sqlite3_exec(handle.pointer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw CoreError.storage }
        do {
            try saveProfiles(profiles)
            try execute("DELETE FROM records WHERE key = ?", key: "chat:\(agentID)")
            guard sqlite3_exec(handle.pointer, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw CoreError.storage }
        } catch { sqlite3_exec(handle.pointer, "ROLLBACK", nil, nil, nil); throw error }
    }

    private func read<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        let statement = try prepare("SELECT value FROM records WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw CoreError.storage }
        let count = Int(sqlite3_column_bytes(statement, 0))
        do { return try decoder.decode(T.self, from: Data(bytes: bytes, count: count)) }
        catch { throw CoreError.storage }
    }

    private func write<T: Encodable>(_ key: String, value: T) throws {
        let data = try encoder.encode(value)
        let statement = try prepare("INSERT INTO records (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement)
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.storage }
    }

    private func execute(_ sql: String, key: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.storage }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CoreError.storage }
        return statement
    }
    private func bind(_ key: String, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw CoreError.storage }
    }
}
