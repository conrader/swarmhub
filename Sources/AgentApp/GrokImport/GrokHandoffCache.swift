import Foundation

/// The summary of a conversation's older part, kept beside its archive as `<id>.handoff.json` (mode 0600), so that it
/// is made once and used by every agent the bot starts afterwards. It is never in `store.json`, and it goes when the
/// archive goes (`GrokHistoryStore.remove`). The text went through the secret filter before it was stored and goes
/// through it again each time the file is loaded.
struct GrokHandoffCache: Codable, Equatable, Sendable {
    private(set) var summary: String
    /// The numbers of the first and the last message it stands for, and how many messages that is.
    var from: Int64, through: Int64
    var messages: Int
    /// The agent program's template and the model that wrote it, as the bot named them (empty: the server's choice).
    var template: String, model: String
    var madeAt: Date

    init(summary: String, from: Int64, through: Int64, messages: Int, template: String, model: String, madeAt: Date) {
        self.summary = GrokHandoff.cleanSummary(summary)
        self.from = from; self.through = through; self.messages = messages
        self.template = template; self.model = model; self.madeAt = madeAt
    }

    static func url(in directory: URL, for id: UUID) -> URL { directory.appending(path: "\(id.uuidString.lowercased()).handoff.json") }

    /// nil when there is no file, it cannot be read, or nothing is left of its summary after the filter.
    static func load(_ url: URL) -> GrokHandoffCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var cache = try? decoder.decode(GrokHandoffCache.self, from: data) else { return nil }
        cache.summary = GrokHandoff.cleanSummary(cache.summary)
        return cache.summary.isEmpty ? nil : cache
    }

    func save(to url: URL, directory: URL) throws {
        try GrokHistoryStore.prepareDirectory(directory)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension GrokHandoff {
    /// An archive read from disk and laid out: what a handoff is rendered from.
    struct Draft: Sendable {
        let transcript: Transcript
        let plan: Plan
        /// The saved summary, when it stands for the plan's older part.
        let cache: GrokHandoffCache?
    }

    /// nil when there is no archive, or nothing was said in it. Reads files: call it off the main actor.
    static func draft(archive: URL, cache cacheURL: URL, botName: String) -> Draft? {
        guard let saved = GrokHistoryStore.linesOnDisk(archive) else { return nil }
        let transcript = Transcript(saved)
        guard !transcript.spoken.isEmpty else { return nil }
        let cache = GrokHandoffCache.load(cacheURL)
        let layout = Self.plan(transcript, botName: botName, summarisedThrough: cache?.through)
        return Draft(transcript: transcript, plan: layout, cache: layout.covered && !layout.older.isEmpty ? cache : nil)
    }

    // MARK: Making the summary

    /// A file of the older part is about this long, and at most `mostParts` of them are summarised (four go with one
    /// message to the agent). A longer older part loses its oldest messages from the summary; they stay in the full
    /// transcript.
    static let partBytes = 120_000, mostParts = 24

    /// The older part as the texts a summary is made from, oldest first, and what they stand for.
    struct Parts: Sendable, Equatable {
        let texts: [String]
        let from: Int64, through: Int64
        let messages: Int

        var files: [HerdrClient.TaskFile] {
            texts.enumerated().map { index, text in
                HerdrClient.TaskFile(name: "older-part-\(index + 1).md", mime: "text/markdown", data: Data(text.utf8))
            }
        }
    }

    /// nil for an empty older part. A message longer than half a file is cut in the middle, like in the recent part.
    static func parts(of older: [ArchivedMessage], botName: String) -> Parts? {
        guard let last = older.last else { return nil }
        var groups: [[String]] = [[]]
        var size = 0, count = 0
        var first = last.seq
        for line in older.reversed() {
            var shown = line
            shown.text = cut(line.text, to: partBytes / 2, seq: line.seq)
            let text = entry(shown, botName: botName)
            if size > 0, size + text.utf8.count > partBytes {
                if groups.count == mostParts { break }
                groups.append([])
                size = 0
            }
            groups[groups.count - 1].append(text)
            size += text.utf8.count
            first = line.seq
            count += 1
        }
        let texts: [String] = groups.reversed().map { $0.reversed().joined() }
        return Parts(texts: texts, from: first, through: last.seq, messages: count)
    }

    /// Has a one-off agent of the bot's own agent program and model, on the bot's own server, summarise the older
    /// part (`HerdrClient.summarise`), and saves what it wrote beside the archive. nil when that failed or took
    /// longer than `limit`: the handoff then goes without a summary. Nothing is saved for an archive that was
    /// removed meanwhile.
    static func summarise(_ draft: Draft, botName: String, archiveID: UUID, client: HerdrClient, template: String?, model: String?,
                          limit: Duration, archive: URL, cache: URL, directory: URL, now: Date) async -> GrokHandoffCache? {
        guard let pieces = Self.parts(of: draft.plan.older, botName: botName) else { return nil }
        let written: String
        do {
            written = try await client.summarise(pieces.files, name: HerdrClient.compactorName(for: archiveID), template: template, model: model, limit: limit)
        } catch { return nil }
        let made = GrokHandoffCache(summary: written, from: pieces.from, through: pieces.through, messages: pieces.messages,
                                    template: template ?? "", model: model ?? "", madeAt: now)
        guard !made.summary.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: archive.path) { try? made.save(to: cache, directory: directory) }
        return made
    }
}
