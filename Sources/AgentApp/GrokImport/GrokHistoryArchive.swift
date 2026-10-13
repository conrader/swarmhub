import Foundation

/// One read-only line of imported Grok Bot history. Never sent to Hermes as a turn.
struct ArchivedMessage: Codable, Equatable, Identifiable {
    var id: String; var seq: Int64; var role: String; var author: String?; var text: String
    var timestamp: Date?; var hidden: Bool; var channel: String; var to: String?

    var dedupeKey: String { id.isEmpty ? "seq:\(seq)" : id }
    func matches(_ query: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query) || (author?.localizedCaseInsensitiveContains(query) ?? false) || (to?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

struct GrokHistoryFile: Codable { var sourceID: String; var messages: [ArchivedMessage] }

/// Per-bot archive files in `<store dir>/grok-history/<bot id>.json` (dir 0700, files 0600).
/// Files are read only when a bot's archive is first opened.
@MainActor final class GrokHistoryStore: ObservableObject {
    let directory: URL
    @Published private(set) var loaded: [UUID: [ArchivedMessage]] = [:]

    init(directory: URL) { self.directory = directory }

    func fileURL(for botID: UUID) -> URL { directory.appending(path: "\(botID.uuidString.lowercased()).json") }
    func isLoaded(_ botID: UUID) -> Bool { loaded[botID] != nil }

    func messages(for botID: UUID) -> [ArchivedMessage] {
        if let cached = loaded[botID] { return cached }
        let messages = read(botID)?.messages ?? []
        loaded[botID] = messages
        return messages
    }

    /// Merges by entry id (or seq when an id is missing); an existing line is replaced by the newer copy.
    /// Returns the merged count.
    @discardableResult func merge(_ incoming: [ArchivedMessage], sourceID: String, for botID: UUID) throws -> Int {
        var byKey: [String: ArchivedMessage] = [:]
        for message in (read(botID)?.messages ?? []) + incoming { byKey[message.dedupeKey] = message }
        let merged = byKey.values.sorted { ($0.seq, $0.timestamp ?? .distantPast, $0.id) < ($1.seq, $1.timestamp ?? .distantPast, $1.id) }
        try write(GrokHistoryFile(sourceID: sourceID, messages: merged), for: botID)
        loaded[botID] = merged
        return merged.count
    }

    func remove(_ botID: UUID) { try? FileManager.default.removeItem(at: fileURL(for: botID)); loaded[botID] = nil }

    private func read(_ botID: UUID) -> GrokHistoryFile? {
        guard let data = try? Data(contentsOf: fileURL(for: botID)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GrokHistoryFile.self, from: data)
    }

    private func write(_ file: GrokHistoryFile, for botID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = fileURL(for: botID)
        try encoder.encode(file).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension ArchivedMessage {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func date(_ value: String?) -> Date? { value.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } }

    /// Bundle messages and rename events → archive lines, every text field through the secret filter.
    static func from(_ bundle: GrokBotBundle) -> [ArchivedMessage] {
        let clean = { (text: String) in GrokTemplateParser.redactSecrets(text, replacement: "[REDACTED]").text }
        let messages = bundle.messages.map { message in
            ArchivedMessage(id: message.id, seq: message.seq, role: ["user", "assistant", "system"].contains(message.role) ? message.role : "system",
                            author: message.author.map(clean), text: clean(message.text), timestamp: date(message.timestamp),
                            hidden: message.hidden ?? false, channel: message.channel ?? "chat", to: message.to.map(clean))
        }
        let renames = bundle.events.compactMap { event -> ArchivedMessage? in
            guard event.event.type == "name-changed", let from = event.event.from, let to = event.event.to else { return nil }
            return ArchivedMessage(id: event.id, seq: event.seq, role: "system", author: nil, text: "Renamed from “\(clean(from))” to “\(clean(to))”",
                                   timestamp: event.timestampMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }, hidden: false, channel: "event", to: nil)
        }
        return messages + renames
    }
}
