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

/// What the Mac remembers about handing a bot its conversation, kept beside the archive as `<id>.handoff-state.json`
/// (mode 0600): never in `store.json`, and gone with the archive. It holds no text of the conversation.
struct GrokHandoffState: Codable, Equatable, Sendable {
    /// The launch of the bot's agent that replied to the handoff. While that launch runs, nothing is sent again,
    /// whatever the server still shows of the session's rows (`HerdrHandoffSource.read`). `readMarker` is the marker
    /// of what it read (with the archive's revision), when this Mac sent it.
    var read: HerdrAgentLaunch? = nil
    var readMarker: String? = nil

    /// The handoff failed and the person's message went without it: for which launch, how often in a row, why, when.
    struct Failures: Codable, Equatable, Sendable {
        var launch: HerdrAgentLaunch
        var count: Int
        var why: String
        var at: Date
    }
    var failures: Failures? = nil

    /// The summary of the older part is not made by itself for now: making it failed (`tooLong` false), which holds
    /// for `GrokHandoffState.summaryPause` from `at`, or the older part is longer than is summarised unasked. Either
    /// way only for the archive as it was then (`revision`): new lines lift it, and so does the person's own request.
    struct SummaryHold: Codable, Equatable, Sendable {
        var revision: String
        var at: Date
        var tooLong: Bool
    }
    var summaryHold: SummaryHold? = nil
    static let summaryPause: TimeInterval = 24 * 60 * 60

    /// The hold applies to this revision of the archive at this moment.
    func holdsSummary(of revision: String, now: Date) -> Bool {
        guard let hold = summaryHold, hold.revision == revision else { return false }
        return hold.tooLong || now.timeIntervalSince(hold.at) < Self.summaryPause
    }

    static func url(in directory: URL, for id: UUID) -> URL { directory.appending(path: "\(id.uuidString.lowercased()).handoff-state.json") }

    /// An empty state when there is no file or it cannot be read.
    static func load(_ url: URL) -> GrokHandoffState {
        guard let data = try? Data(contentsOf: url) else { return GrokHandoffState() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(GrokHandoffState.self, from: data)) ?? GrokHandoffState()
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
        /// The saved summary of the older part. It may stand for less than the whole of it (`plan.covered` false):
        /// it is still used until a new one is there.
        let cache: GrokHandoffCache?
        /// How many files the older part makes when it has to be summarised; 0 when it needs no summary.
        var parts = 0
    }

    /// nil when there is no archive, or nothing was said in it. Reads files: call it off the main actor.
    static func draft(archive: URL, cache cacheURL: URL, botName: String) -> Draft? {
        guard let saved = GrokHistoryStore.linesOnDisk(archive) else { return nil }
        let transcript = Transcript(saved)
        guard !transcript.spoken.isEmpty else { return nil }
        let cache = GrokHandoffCache.load(cacheURL)
        let layout = Self.plan(transcript, botName: botName, summarisedThrough: cache?.through)
        // A saved summary that ends before the older part starts says nothing about it.
        var usable: GrokHandoffCache? = nil
        if let saved = cache, let oldest = layout.older.first, saved.through >= oldest.seq { usable = saved }
        let count = layout.needsSummary ? (parts(of: layout.older, botName: botName)?.texts.count ?? 0) : 0
        return Draft(transcript: transcript, plan: layout, cache: usable, parts: count)
    }

    // MARK: Making the summary

    /// A file of the older part is about this long, and at most `mostParts` of them are summarised (four go with one
    /// message to the agent). A longer older part loses its oldest messages from the summary; they stay in the full
    /// transcript. By itself the app summarises an older part of at most `unaskedParts` files; a longer one waits for
    /// the person to ask, because it takes the agent several rounds and may not fit what it can read.
    static let partBytes = 120_000, mostParts = 24, unaskedParts = 8

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
            shown.text = cut(line.text, to: partBytes / 2, seq: line.seq, whole: false)
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
