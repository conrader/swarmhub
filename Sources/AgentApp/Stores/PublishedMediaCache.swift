import CryptoKit
import Foundation

/// A bounded local copy of media already shown in chat. The server's journal remains the source
/// for a new download if macOS reclaims the cache or the result has aged out.
actor PublishedMediaCache {
    static let shared = PublishedMediaCache()
    private let directory: URL
    private let byteLimit: Int
    private let fileLimit: Int

    init(directory: URL? = nil, byteLimit: Int = 256 * 1024 * 1024, fileLimit: Int = 512) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "SwarmHub")
            .appending(path: "ChatMedia", directoryHint: .isDirectory)
        self.byteLimit = byteLimit
        self.fileLimit = fileLimit
    }

    func data(for item: HerdrPublishedResult, in message: UUID, storeURL: URL,
              server: HerdrServer, client: HerdrClient) async throws -> Data {
        // The local port of an SSH forward can change between launches. Key on the configured
        // workspace and credential instead. Only the hash is written to the cache directory.
        let identity = [storeURL.standardizedFileURL.path, message.uuidString, server.id, server.kind.rawValue,
                        server.address, server.sshHost, server.sshUser, client.token, String(item.id), item.title]
        let hash = SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appending(path: hash)
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return data
        }
        let data = try await client.publishedFile(id: item.id)
        try Task.checkCancellation()
        if data.count <= byteLimit {
            // A full or read-only cache must still let the user view a successful download.
            try? save(data, to: url)
        }
        return data
    }

    private func save(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let entries = try urls.map { ($0, try $0.resourceValues(forKeys: keys)) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.1.fileSize ?? 0
            if index >= fileLimit || bytes > byteLimit { try? fm.removeItem(at: entry.0) }
        }
    }
}

extension AppStore {
    func publishedReplyFile(_ item: HerdrPublishedResult, messageID: UUID, serverID: String) async throws -> Data {
        guard let server = herdrServer(id: serverID) else { throw BackendError.unavailable("The server that published this result is no longer configured.") }
        let client = try herdrClient(for: server)
        guard ChatMediaKind(filename: item.title) != nil else { return try await client.publishedFile(id: item.id) }
        return try await PublishedMediaCache.shared.data(for: item, in: messageID, storeURL: fileURL, server: server, client: client)
    }
}
