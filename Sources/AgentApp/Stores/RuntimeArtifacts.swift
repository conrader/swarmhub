import CryptoKit
import Foundation

/// P38: a document saved for later use, with the bots allowed to read it.
struct RuntimeArtifact: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var mimeType: String
    var byteCount: Int
    var sha256: String
    var ownerBotIDs: [UUID]
    var createdAt: Date = .now
}

/// P38: `artifacts/` next to store.json: one file per artifact plus `index.json` (id, name, size, SHA-256, readers).
/// A read checks access and integrity. (Part D's ledger can take over the index; the files stay.)
@MainActor final class RuntimeArtifacts {
    static let byteLimit = 10 * 1024 * 1024
    let directory: URL
    init(directory: URL) { self.directory = directory }

    private var indexURL: URL { directory.appending(path: "index.json") }
    func fileURL(_ id: UUID) -> URL { directory.appending(path: id.uuidString.lowercased() + ".txt") }

    func records() throws -> [RuntimeArtifact] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RuntimeArtifact].self, from: Data(contentsOf: indexURL))
    }

    func record(_ id: UUID) throws -> RuntimeArtifact? { try records().first { $0.id == id } }

    /// Adds or replaces one entry of the index.
    func put(_ artifact: RuntimeArtifact) throws {
        var all = try records().filter { $0.id != artifact.id }; all.append(artifact)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(all).write(to: indexURL, options: .atomic)
    }

    func save(_ data: Data, name: String, mimeType: String, owners: [UUID]) throws -> RuntimeArtifact {
        guard data.count <= Self.byteLimit else { throw BackendError.unavailable("This document is larger than the 10 MB limit for saved documents.") }
        guard !owners.isEmpty else { throw BackendError.unavailable("A saved document needs at least one agent with access.") }
        var seen = Set<UUID>()
        let artifact = RuntimeArtifact(id: UUID(), name: String(name.prefix(200)), mimeType: mimeType, byteCount: data.count,
                                       sha256: Self.digest(data), ownerBotIDs: owners.filter { seen.insert($0).inserted })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(artifact.id), options: .atomic)
        do { try put(artifact) } catch { try? FileManager.default.removeItem(at: fileURL(artifact.id)); throw error }
        return artifact
    }

    /// The content for `botID`; throws when the bot has no access or the file no longer matches its digest.
    func read(_ id: UUID, botID: UUID) throws -> Data {
        guard let record = try record(id), record.ownerBotIDs.contains(botID) else { throw BackendError.unavailable("This agent does not have access to that saved document.") }
        let data = try Data(contentsOf: fileURL(id))
        guard data.count == record.byteCount, Self.digest(data) == record.sha256 else { throw BackendError.unavailable("The saved document “\(record.name)” changed on disk and was not used.") }
        return data
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
