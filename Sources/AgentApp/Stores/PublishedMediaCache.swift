import CryptoKit
import Foundation

/// Helper replies have journal or thread identities instead of a persisted ChatMessage UUID.
struct HelperReplyMedia {
    let server: HerdrServer
    let core: String
    let agent: HerdrClient.AgentRef
    let entry: [String]

    var published: HerdrReplyResults?

    var replyID: UUID { cacheID(entry) }
    // Downloaded results are also keyed by their immutable workspace journal ID.
    var publicationID: UUID { cacheID(["publications"]) }

    private func cacheID(_ entry: [String]) -> UUID {
        let fields = ["helper-reply", server.id, server.kind.rawValue, server.address,
                      core, agent.address, String(agent.createdMs)] + entry
        // Length prefixes keep paths, thread identifiers and arbitrary text unambiguous.
        var hash = SHA256()
        for field in fields {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: Data(field.utf8))
        }
        return hash.finalize().withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

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

extension PublishedMediaCache {
    /// Retain a message-scoped copy before temporary screenshots and clips are removed.
    func localFile(_ source: URL, message: UUID, storeURL: URL) throws -> URL {
        let identity = [storeURL.standardizedFileURL.path, message.uuidString, source.path]
        let hash = SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
        let cached = directory.appendingPathComponent(hash).appendingPathExtension(source.pathExtension)
        let fm = FileManager.default
        if fm.fileExists(atPath: cached.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            return cached
        }
        let file = source.resolvingSymlinksInPath().standardizedFileURL
        let roots = [URL(fileURLWithPath: "/tmp"), fm.temporaryDirectory,
                     fm.homeDirectoryForCurrentUser.appending(path: "swarmhub-agents")]
        guard roots.contains(where: { file.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }),
              let attrs = try? fm.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else {
            throw BackendError.unavailable("Ask the bot to attach this file again.")
        }
        guard size <= byteLimit else { return file }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        do { try save(data, to: cached); return cached }
        catch { return file }
    }
}

extension AppStore {
    func replyMediaIsOnThisMac(_ message: ChatMessage, target: ConversationActionTarget?) -> Bool {
        // A bot can move. The server stamped on the actual reply takes precedence over its current home.
        if let receipt = message.metadata["herdrJournal"] ?? message.metadata["herdrTeamEntry"],
           let key = receipt.split(separator: " ").first, let colon = key.lastIndex(of: ":") {
            return herdrServer(id: String(key[..<colon]))?.kind == .local
        }
        guard let target, let (bot, _) = actionConversation(target), bot.backend == .herdr, !bot.isDemo else { return false }
        return herdrServer(for: bot).kind == .local
    }
}
