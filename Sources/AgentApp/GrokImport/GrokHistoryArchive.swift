import Foundation

/// One read-only line of imported Grok Bot history. Never sent to an agent as a turn.
struct ArchivedMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String; var seq: Int64; var role: String; var author: String?; var text: String
    var timestamp: Date?; var hidden: Bool; var channel: String; var to: String?
    var streaming: Bool? = nil

    var dedupeKey: String { id.isEmpty ? "seq:\(seq)" : id }
    func matches(_ query: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query) || (author?.localizedCaseInsensitiveContains(query) ?? false) || (to?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

struct GrokHistoryFile: Codable, Sendable { var sourceID: String; var messages: [ArchivedMessage] }

/// Per-bot archive files in `<store dir>/grok-history/<bot id>.json` (dir 0700, files 0600).
/// Files are read only when a bot's archive is first opened.
@MainActor final class GrokHistoryStore: ObservableObject {
    let directory: URL
    @Published private(set) var loaded: [UUID: [ArchivedMessage]] = [:]
    /// The sidebar's newest-line cache; not published, so reading it while a view draws changes nothing.
    private var newestCache: [UUID: ArchivedMessage?] = [:]

    init(directory: URL) { self.directory = directory }

    func fileURL(for botID: UUID) -> URL { directory.appending(path: "\(botID.uuidString.lowercased()).json") }
    func isLoaded(_ botID: UUID) -> Bool { loaded[botID] != nil }

    /// The newest visible archived line (P20 sidebar fragment); reads the file at most once per merge.
    func newestVisible(for botID: UUID) -> ArchivedMessage? {
        if let messages = loaded[botID] { return Self.newestVisible(in: messages) }
        if let cached = newestCache[botID] { return cached }
        let newest = Self.newestVisible(in: read(botID)?.messages ?? [])
        newestCache[botID] = .some(newest)
        return newest
    }
    nonisolated static func newestVisible(in messages: [ArchivedMessage]) -> ArchivedMessage? {
        messages.last { !$0.hidden && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func messages(for botID: UUID) -> [ArchivedMessage] {
        if let cached = loaded[botID] { return cached }
        let messages = read(botID)?.messages ?? []
        loaded[botID] = messages
        return messages
    }

    /// Merges by entry id (or seq when an id is missing); an existing line is replaced by the newer copy.
    /// Returns the merged count. An existing file that cannot be read is set aside, never overwritten.
    @discardableResult func merge(_ incoming: [ArchivedMessage], sourceID: String, for botID: UUID) throws -> Int {
        let merged = try Self.mergeOnDisk(incoming, sourceID: sourceID, url: fileURL(for: botID), directory: directory)
        loaded[botID] = merged; newestCache[botID] = nil
        return merged.count
    }

    /// `merge`, with the file read, sort, encode and write off the main actor (the in-app import path).
    @discardableResult func mergeInBackground(_ incoming: [ArchivedMessage], sourceID: String, for botID: UUID,
                                               settledFetchedSequences: Set<Int64> = []) async throws -> Int {
        let url = fileURL(for: botID), directory = directory
        let merged = try await Task.detached(priority: .userInitiated) {
            try Self.mergeOnDisk(incoming, sourceID: sourceID, url: url, directory: directory,
                                 settledFetchedSequences: settledFetchedSequences)
        }.value
        loaded[botID] = merged; newestCache[botID] = nil
        return merged.count
    }

    /// When the archive file was last written ("already imported <date>"); nil when there is none.
    func lastModified(for botID: UUID) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL(for: botID).path))?[.modificationDate] as? Date
    }

    /// Lines in the archive file as it is on disk now (the Done step reads counts back from the files); nil = no file.
    func lineCountOnDisk(for botID: UUID) -> Int? { read(botID)?.messages.count }

    func remove(_ botID: UUID) { try? FileManager.default.removeItem(at: fileURL(for: botID)); loaded[botID] = nil; newestCache[botID] = nil }

    private func read(_ botID: UUID) -> GrokHistoryFile? { Self.read(fileURL(for: botID)) }

    nonisolated private static func read(_ url: URL) -> GrokHistoryFile? { (try? Data(contentsOf: url)).flatMap(decode) }

    nonisolated private static func decode(_ data: Data) -> GrokHistoryFile? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GrokHistoryFile.self, from: data)
    }

    nonisolated static func mergeOnDisk(_ incoming: [ArchivedMessage], sourceID: String, url: URL,
                                        directory: URL, settledFetchedSequences: Set<Int64> = []) throws -> [ArchivedMessage] {
        var existing: [ArchivedMessage] = []
        if FileManager.default.fileExists(atPath: url.path) {
            // A file that cannot be opened right now may be a good archive: only one that opens and does not decode is set aside.
            guard let data = try? Data(contentsOf: url) else { throw GrokHistoryError.archiveUnavailable(url.lastPathComponent) }
            guard let file = decode(data) else { throw GrokHistoryError.archiveUnreadable(keptAs: try setAside(url)) }
            guard file.sourceID == sourceID else { throw GrokHistoryError.sourceMismatch }
            // Lines saved under an older secret filter go through today's, so a better filter also cleans what is on disk.
            existing = file.messages.map(\.refiltered)
        }
        var byKey: [String: ArchivedMessage] = [:]
        for message in existing + incoming {
            if let saved = byKey[message.dedupeKey] {
                if message.streaming == true, saved.streaming != true { continue }
                if message.text.utf8.count < saved.text.utf8.count,
                   message.streaming == true || !settledFetchedSequences.contains(message.seq),
                   !message.isMoreRedacted(than: saved) { continue }
            }
            byKey[message.dedupeKey] = message
        }
        let merged = byKey.values.sorted { ($0.seq, $0.timestamp ?? .distantPast, $0.id) < ($1.seq, $1.timestamp ?? .distantPast, $1.id) }
        try write(GrokHistoryFile(sourceID: sourceID, messages: merged), to: url, directory: directory)
        return merged
    }

    /// Renames an undecodable archive to `<id>.json.corrupt-<UTC stamp>` (0600, the stamp style `store.json` uses).
    nonisolated private static func setAside(_ url: URL) throws -> String {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).corrupt-\(stamp)")
        do { try FileManager.default.moveItem(at: url, to: backup) }
        catch { throw GrokHistoryError.archiveUnmovable(url.lastPathComponent) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup.lastPathComponent
    }

    nonisolated static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    nonisolated private static func write(_ file: GrokHistoryFile, to url: URL, directory: URL) throws {
        try prepareDirectory(directory)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum GrokHistoryError: LocalizedError, Equatable {
    /// The existing archive could not be decoded; it was renamed, nothing deleted, nothing merged.
    case archiveUnreadable(keptAs: String)
    case archiveUnmovable(String)
    /// The existing archive could not be opened (an I/O error, not a bad file): nothing was moved, merged or changed.
    case archiveUnavailable(String)
    case sourceMismatch

    var errorDescription: String? {
        switch self {
        case .sourceMismatch: "The saved archive belongs to another conversation."
        case .archiveUnreadable(let name): "A history archive could not be read; it was kept as \(name), nothing deleted."
        case .archiveUnmovable(let name): "The history archive \(name) could not be read or set aside; nothing was changed."
        case .archiveUnavailable(let name): "The history archive \(name) could not be opened; nothing was changed. If it keeps happening, check that the file can be read."
        }
    }
}

extension ArchivedMessage {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func date(_ value: String?) -> Date? { value.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } }

    /// The same message as `saved` with more of it replaced by the marker: every stretch of this text between markers is
    /// in `saved`, in order. A shorter copy is normally an older or half-written one and does not replace a saved line;
    /// this one is shorter because today's filter took what an older filter left behind, so it does.
    func isMoreRedacted(than saved: ArchivedMessage) -> Bool {
        guard streaming != true else { return false }
        let pieces = text.components(separatedBy: GrokRedactor.marker)
        guard pieces.count > 1 else { return false }
        var searchFrom = saved.text.startIndex
        for piece in pieces where !piece.isEmpty {
            guard let found = saved.text.range(of: piece, range: searchFrom..<saved.text.endIndex) else { return false }
            searchFrom = found.upperBound
        }
        return true
    }

    /// The same line with every text field through the secret filter again (a line already filtered comes back unchanged).
    var refiltered: ArchivedMessage {
        let clean = { (text: String) in SecretFilter.redacted(text, replacement: GrokRedactor.marker) }
        var line = self
        line.text = clean(text); line.author = author.map(clean); line.to = to.map(clean)
        return line
    }

    /// Bundle messages and rename events → archive lines, every text field through the secret filter.
    static func from(_ bundle: GrokBotBundle) -> [ArchivedMessage] {
        let clean = { (text: String) in SecretFilter.redacted(text, replacement: GrokRedactor.marker) }
        let messages = bundle.messages.map { message in
            ArchivedMessage(id: message.id, seq: message.seq, role: ["user", "assistant", "system"].contains(message.role) ? message.role : "system",
                            author: message.author.map(clean), text: clean(message.text), timestamp: date(message.timestamp),
                            hidden: message.hidden ?? false, channel: message.channel ?? "chat", to: message.to.map(clean), streaming: message.streaming)
        }
        let renames = bundle.events.compactMap { event -> ArchivedMessage? in
            guard event.event.type == "name-changed", let from = event.event.from, let to = event.event.to else { return nil }
            return ArchivedMessage(id: event.id, seq: event.seq, role: "system", author: nil, text: "Renamed from “\(clean(from))” to “\(clean(to))”",
                                   timestamp: event.timestampMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }, hidden: false, channel: "event", to: nil)
        }
        return messages + renames
    }
}
