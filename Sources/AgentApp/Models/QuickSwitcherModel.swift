import Foundation

/// The quick switcher's rows and its keyboard highlight. The first enabled match is highlighted; up and down move
/// over enabled rows and stop at the ends; Return opens the highlighted row.
struct QuickSwitcherModel: Equatable {
    struct Item: Identifiable, Equatable {
        enum Target: Equatable { case bot(UUID), group(UUID), message(ChatMessageLocation), command(AppCommand), setup }
        var id: String; var title: String; var icon: String; var detail: String? = nil; var shortcut: String? = nil; var isEnabled = true; var target: Target
        /// Commands come after a divider.
        var isCommand: Bool { switch target { case .bot, .group, .message: false; case .command, .setup: true } }
    }

    private(set) var items: [Item] = []
    private(set) var highlighted: String?

    init(items: [Item] = []) { update(items) }

    /// New matches (the query changed): the first enabled one is highlighted.
    mutating func update(_ items: [Item]) {
        self.items = items
        highlighted = items.first(where: \.isEnabled)?.id
    }

    mutating func move(by offset: Int) {
        let enabled = items.filter(\.isEnabled)
        guard !enabled.isEmpty else { highlighted = nil; return }
        let index = enabled.firstIndex { $0.id == highlighted } ?? (offset > 0 ? -1 : enabled.count)
        highlighted = enabled[min(max(index + offset, 0), enabled.count - 1)].id
    }

    mutating func highlight(_ id: String) { if items.contains(where: { $0.id == id && $0.isEnabled }) { highlighted = id } }

    var selection: Item? { items.first { $0.id == highlighted && $0.isEnabled } }

    private struct MessageRow: Sendable {
        let location: ChatMessageLocation
        let chat: String
        let author: String
        let date: Date?
        let role: MessageRole
        let content: String

        /// The text someone can read in the transcript, including prose before tool steps.
        var searchableText: String {
            guard role != .system, content.rangeOfCharacter(from: Self.markup) != nil else { return content }
            return role == .assistant ? TranscriptText(reply: content, segments: nil).string : TranscriptText(user: content).string
        }
        private static let markup = CharacterSet(charactersIn: "*_`~[<>\\#!|")
    }

    /// Snapshot the local rows on the main actor. Text parsing, matching and sorting can run
    /// away from the chat window while the person types their next character.
    @MainActor static func messages(in store: AppStore, query: String, files: ArchiveFiles = ArchiveFiles(),
                                    liveResults: (@MainActor @Sendable ([Item]) -> Void)? = nil) async -> [Item] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let chats = store.bots.map { ($0.id, $0.name, $0.messages) } + store.groups.map { ($0.id, $0.name, $0.messages) }
        var rows: [MessageRow] = []
        for (id, name, messages) in chats {
            for (index, message) in messages.enumerated() {
                if index.isMultiple(of: 128) {
                    await Task.yield()
                    if Task.isCancelled { return [] }
                }
                guard !message.isSilent else { continue }
                let body: String
                if let title = message.metadata["herdrExchangeTitle"] { body = title + "\n" + message.content }
                else if message.metadata[HerdrIntro.Key.kind] != nil || message.metadata[HerdrBotRelay.Key.kind] != nil {
                    body = store.displayLine(message)
                } else { body = message.content }
                let location = ChatMessageLocation(conversation: id, message: message.id)
                rows.append(MessageRow(location: location, chat: name, author: store.copyAuthor(message, botName: name),
                                       date: message.transcriptDate, role: message.role, content: body))
            }
        }
        let archives = store.bots.compactMap { $0.grokSourceID == nil ? nil : ($0.id, $0.name) }
            + store.groups.compactMap { $0.grokSourceID == nil ? nil : ($0.id, $0.name) }
        let sources = archives.map { (id, name) in
            ArchiveSource(id: id, name: name, url: store.grokHistory.fileURL(for: id), cached: store.grokHistory.loaded[id])
        }
        return await matches(in: rows, archives: sources, files: files, term: term, timeZone: store.personDisplayZone, liveResults: liveResults)
    }

    private struct ArchiveSource: Sendable {
        let id: UUID
        let name: String
        let url: URL
        let cached: [ArchivedMessage]?
    }

    /// A search sheet reuses decoded archive files as the person refines their query.
    actor ArchiveFiles {
        private var entries: [URL: (modified: Date, size: Int, messages: [ArchivedMessage])] = [:]

        func messages(at url: URL) -> [ArchivedMessage] {
            guard !Task.isCancelled, let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize else { return [] }
            if let entry = entries[url], entry.modified == modified, entry.size == size { return entry.messages }
            let messages = GrokHistoryStore.linesOnDisk(url) ?? []
            entries[url] = (modified, size, messages)
            return messages
        }
    }

    private static func matches(in rows: [MessageRow], archives: [ArchiveSource], files: ArchiveFiles, term: String,
                                timeZone: TimeZone, liveResults: (@MainActor @Sendable ([Item]) -> Void)?) async -> [Item] {
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)
        var matches: [(date: Date, item: Item)] = []
        func match(_ row: MessageRow, imported: Bool = false) {
            let body = row.searchableText
            guard let found = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) else { return }
            let start = body.index(found.lowerBound, offsetBy: -32, limitedBy: body.startIndex) ?? body.startIndex
            let end = body.index(found.upperBound, offsetBy: 64, limitedBy: body.endIndex) ?? body.endIndex
            let excerpt = body[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let title = (start == body.startIndex ? "" : "…") + excerpt + (end == body.endIndex ? "" : "…")
            let source = row.author == row.chat ? row.chat : "\(row.chat) · \(row.author)"
            let detail = [source, imported ? "Grok history" : nil, row.date?.formatted(dateStyle)].compactMap { $0 }.joined(separator: " · ")
            let item = Item(id: row.location.id, title: title,
                            icon: "text.bubble", detail: detail, target: .message(row.location))
            matches.append((row.date ?? .distantPast, item))
        }
        for row in rows {
            if Task.isCancelled { return [] }
            match(row)
        }
        if !archives.isEmpty, !matches.isEmpty, let liveResults, !Task.isCancelled {
            await liveResults(matches.sorted { $0.date > $1.date }.map(\.item))
        }
        for archive in archives {
            if Task.isCancelled { return [] }
            let messages: [ArchivedMessage]
            if let cached = archive.cached { messages = cached }
            else { messages = await files.messages(at: archive.url) }
            for entry in messages.reversed() where !entry.hidden {
                if Task.isCancelled { return [] }
                let location = ChatMessageLocation(conversation: archive.id, imported: entry.dedupeKey)
                // The archive shows its original plain text, including any Markdown punctuation.
                match(MessageRow(location: location, chat: archive.name, author: entry.heading(botName: archive.name),
                                 date: entry.timestamp, role: .system, content: entry.text), imported: true)
            }
        }
        return matches.sorted { $0.date > $1.date }.map(\.item)
    }

    @MainActor static func items(in store: AppStore, query: String) -> [Item] {
        func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }
        var items = store.bots.filter { matches($0.name) }.map { Item(id: "bot-\($0.id)", title: $0.name, icon: "message", target: .bot($0.id)) }
        items += store.groups.filter { matches($0.name) }.map { Item(id: "group-\($0.id)", title: $0.name, icon: "person.3", target: .group($0.id)) }
        items += AppCommand.allCases.filter { $0 != .quickSwitcher && matches($0.title) }.map {
            Item(id: "command-\($0.rawValue)", title: $0.title, icon: $0.icon, shortcut: $0.shortcutText, isEnabled: $0.isEnabled(in: store), target: .command($0))
        }
        let setup = store.setupAddsServer ? SimpleCopy.addServer : SimpleCopy.setUp
        if matches(setup) { items.append(Item(id: "setup", title: setup, icon: "link", target: .setup)) }
        return items
    }
}
