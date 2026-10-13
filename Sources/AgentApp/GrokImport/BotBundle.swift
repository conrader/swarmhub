import Foundation

/// `agentapp-bot-bundle/v1` as written by `scripts/export-grokbot.py` (spec: docs/agentapp-bot-bundle-v1.md) or built in
/// memory by `GrokBundleBuilder`. Lenient: every field added after P6 is optional, so older bundles still decode.
struct GrokBotBundle: Decodable, Equatable, Sendable {
    struct Avatar: Decodable, Equatable, Sendable { var shape: String?; var colour: String? }
    struct Member: Decodable, Equatable, Sendable { var sourceId: String; var name: String; var profile: String? }
    struct Attachment: Decodable, Equatable, Sendable { var file: String; var available: Bool? }
    struct Message: Decodable, Equatable, Sendable {
        var id: String; var seq: Int64; var role: String; var author: String?; var text: String
        var timestamp: String?; var hidden: Bool?; var channel: String?; var to: String?
        var attachments: [Attachment]?; var replyTo: String?; var thread: String?
    }
    struct Event: Decodable, Equatable, Sendable {
        struct Payload: Decodable, Equatable, Sendable { var type: String; var from: String?; var to: String? }
        var id: String; var seq: Int64; var timestampMs: Int64?; var event: Payload
    }
    struct Source: Decodable, Equatable, Sendable {
        var hiddenFromSidebar: Bool?; var createdAtMs: Int64?; var harness: String?; var notifyOnAgentUpdates: Bool?
    }
    /// Counts only; unknown keys (`server_history`) are ignored.
    struct Statistics: Decodable, Equatable, Sendable {
        var transcriptRows: Int?; var messages: Int?; var events: Int?; var toolEntriesDropped: Int?
        var eventsDropped: Int?; var cardsDropped: Int?; var hiddenMessages: Int?
    }
    var format: String
    var sourceId: String
    var slug: String?
    var name: String
    var description: String?
    var title: String?
    var avatar: Avatar?
    var instructions: String?
    var profile: String?
    var isGroup: Bool?
    var members: [Member]?
    var messages: [Message]
    var events: [Event]
    var source: Source?
    var limitations: [String]?
    var statistics: Statistics?
}

enum GrokBundleError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unreadable(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): "Unsupported export format “\(format)”. Expected \(GrokBundleLoader.format)."
        case .unreadable(let name): "\(name) is not a readable bot bundle export."
        case .unsafePath(let path): "The export index references an unsafe path: \(path)"
        }
    }
}

enum GrokBundleLoader {
    static let format = "agentapp-bot-bundle/v1"
    static let maximumBytes = 64 * 1024 * 1024

    /// Loads an export folder (with `index.json`), an `index.json`, or a single `bundle.json`.
    static func load(from url: URL) throws -> [GrokBotBundle] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw GrokBundleError.unreadable(url.lastPathComponent) }
        if isDirectory.boolValue { return try loadIndex(url.appending(path: "index.json")) }
        let object = try json(at: url)
        return object["bots"] != nil ? try loadIndex(url) : [try decodeBundle(object, name: url.lastPathComponent)]
    }

    private static func loadIndex(_ indexURL: URL) throws -> [GrokBotBundle] {
        let index = try json(at: indexURL)
        try checkFormat(index)
        guard let bots = index["bots"] as? [[String: Any]] else { throw GrokBundleError.unreadable(indexURL.lastPathComponent) }
        let root = indexURL.deletingLastPathComponent()
        return try bots.map { entry in
            guard let path = entry["bundle"] as? String else { throw GrokBundleError.unreadable(indexURL.lastPathComponent) }
            let parts = path.split(separator: "/")
            guard !path.hasPrefix("/"), !path.contains("\\"), !parts.contains(where: { $0 == ".." || $0 == "." }), path.hasSuffix(".json") else { throw GrokBundleError.unsafePath(path) }
            return try decodeBundle(try json(at: root.appending(path: path)), name: path)
        }
    }

    private static func json(at url: URL) throws -> [String: Any] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true, (values?.fileSize ?? 0) <= maximumBytes,
              let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GrokBundleError.unreadable(url.lastPathComponent) }
        return object
    }

    private static func checkFormat(_ object: [String: Any]) throws {
        let found = object["format"] as? String ?? "missing"
        guard found == format else { throw GrokBundleError.unsupportedFormat(found) }
    }

    private static func decodeBundle(_ object: [String: Any], name: String) throws -> GrokBotBundle {
        try checkFormat(object)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(GrokBotBundle.self, from: JSONSerialization.data(withJSONObject: object)) }
        catch { throw GrokBundleError.unreadable(name) }
    }
}
