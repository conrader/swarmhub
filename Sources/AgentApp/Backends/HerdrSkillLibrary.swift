import Foundation

// A Herdr server's skillshare library as its workspace reports it from API level 2 (`HerdrWorkspace/README.md`,
// "Manage the server's skillshare library"). skillshare keeps one library, the source, of five kinds of things an
// agent program can use, and a sync brings it into each agent program's own folders and settings, its Targets. The
// workspace keeps no copy: every answer is what skillshare says at that moment. These are the answers as values,
// and what a screen works out from them (groups, counts, where things stand). Foundation only and on their own, so
// they also build on Linux to check decoding against a real workspace; the routes are in `HerdrSkillLibraryClient.swift`.
// Every field is optional with a default: an answer with less in it still reads.

/// From which API level a workspace serves the library routes (`bridge.api` in `/api/workspace`). An older one
/// serves the first six skill routes only, and the app shows its switch list (`HerdrSkillsModel`).
enum HerdrLibraryGate {
    static let level = 2
    static func open(api: Int?) -> Bool { (api ?? 0) >= level }
}

/// The five kinds of things a library holds.
enum HerdrLibraryKind: String, CaseIterable, Sendable, Identifiable {
    case skills, agents, mcp, plugins, hooks
    var id: String { rawValue }

    /// "Skills", "MCP servers".
    var title: String {
        switch self { case .skills: "Skills"; case .agents: "Agents"; case .mcp: "MCP servers"; case .plugins: "Plugins"; case .hooks: "Hooks" }
    }
    /// "skill", "MCP server".
    var noun: String {
        switch self { case .skills: "skill"; case .agents: "agent"; case .mcp: "MCP server"; case .plugins: "plugin"; case .hooks: "hook" }
    }
    /// "1 skill", "2 MCP servers".
    func counted(_ count: Int) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
    /// What one of this kind is, in a sentence, for a person who has not met the word.
    var explained: String {
        switch self {
        case .skills: "Instructions a bot follows for one kind of job."
        case .agents: "Ready-made helpers a bot can hand a job to."
        case .mcp: "Outside tools and services a bot can use."
        case .plugins: "Add-ons for the AI program itself."
        case .hooks: "Small commands the AI program runs at set moments."
        }
    }
    var symbol: String {
        switch self { case .skills: "puzzlepiece.extension.fill"; case .agents: "person.2.fill"; case .mcp: "powerplug.fill"; case .plugins: "shippingbox.fill"; case .hooks: "bolt.fill" }
    }
}

/// A value the workspace sends as text, a number, a list or a small object: read as the parts a person would see.
struct HerdrLooseValue: Decodable, Sendable, Equatable {
    var parts: [String]
    init(_ parts: [String]) { self.parts = parts }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { parts = [] }
        else if let text = try? c.decode(String.self) { parts = text.isEmpty ? [] : [text] }
        else if let flag = try? c.decode(Bool.self) { parts = [flag ? "yes" : "no"] }
        else if let number = try? c.decode(Int.self) { parts = [String(number)] }
        else if let number = try? c.decode(Double.self) { parts = [String(number)] }
        else if let list = try? c.decode([HerdrLooseValue].self) { parts = list.flatMap(\.parts) }
        else if let object = try? c.decode([String: HerdrLooseValue].self) {
            parts = object.keys.sorted().map { key in
                let value = object[key]?.text ?? ""
                return value.isEmpty ? key : "\(key): \(value)"
            }
        } else { parts = [] }
    }
    var text: String { parts.joined(separator: ", ") }
    var isEmpty: Bool { parts.isEmpty }
}

/// One thing in the library.
struct HerdrLibraryItem: Decodable, Sendable, Equatable, Identifiable {
    /// Where it stands: a sync would change a Target, the last check found a newer version, nothing to do, disabled,
    /// or the part that would say could not be read.
    enum State: String, Sendable, CaseIterable { case waiting, update, inSync = "in_sync", off, unknown }
    /// One Target a sync would change, and what it would do there (`add`, `update`, `remove`, …).
    struct Waiting: Decodable, Sendable, Equatable {
        var target: String = ""
        var action: String? = nil
        enum CodingKeys: CodingKey { case target, action }
        init(target: String, action: String? = nil) { self.target = target; self.action = action }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""; action = try? c.decodeIfPresent(String.self, forKey: .action)
        }
    }

    /// The kind, a colon and skillshare's name for it; sent back as it is.
    let id: String
    var kind: String
    var name: String
    var title: String? = nil
    var path: String? = nil
    var description: String? = nil
    var state: State = .unknown
    var enabled: Bool = true
    /// `local`, `tracked`, or the kind of place it was installed from; and that place.
    var origin: String? = nil
    var source: String? = nil
    var version: String? = nil
    /// The Targets it goes to, and the ones a sync would change.
    var targets: [String] = []
    var waiting: [Waiting] = []
    /// What the workspace will do for it: `enable`, `disable`, `update`, `uninstall`, `diff`.
    var actions: [String] = []

    enum CodingKeys: CodingKey { case id, kind, name, title, path, description, state, enabled, origin, source, version, targets, waiting, actions }
    init(id: String? = nil, kind: HerdrLibraryKind, name: String, description: String? = nil, state: State = .inSync, enabled: Bool? = nil, origin: String? = "local",
         source: String? = nil, version: String? = nil, targets: [String] = [], waiting: [Waiting] = [], actions: [String] = []) {
        self.id = id ?? "\(kind.rawValue):\(name)"; self.kind = kind.rawValue; self.name = name; title = name; path = name; self.description = description
        self.state = state; self.enabled = enabled ?? (state != .off); self.origin = origin; self.source = source; self.version = version
        self.targets = targets; self.waiting = waiting; self.actions = actions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? HerdrLibraryKind.skills.rawValue
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? "\(kind):\(name)"
        if name.isEmpty { name = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id }
        title = try? c.decodeIfPresent(String.self, forKey: .title); path = try? c.decodeIfPresent(String.self, forKey: .path)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        state = (try? c.decodeIfPresent(String.self, forKey: .state)).flatMap(State.init(rawValue:)) ?? .unknown
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? (state != .off)
        origin = try? c.decodeIfPresent(String.self, forKey: .origin); source = try? c.decodeIfPresent(String.self, forKey: .source)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        targets = (try? c.decodeIfPresent([String].self, forKey: .targets)) ?? []; waiting = (try? c.decodeIfPresent([Waiting].self, forKey: .waiting)) ?? []
        actions = (try? c.decodeIfPresent([String].self, forKey: .actions)) ?? []
    }

    /// nil for a kind this app does not know yet; such a thing still shows, as itself.
    var known: HerdrLibraryKind? { HerdrLibraryKind(rawValue: kind) }
    /// The name as people read it: "Code review" for `code-review`. A title the server gives that differs from the name wins.
    var readable: String {
        if let title, !title.isEmpty, title != name { return title }
        return HerdrLibraryCopy.readable(name)
    }
    func can(_ action: String) -> Bool { actions.contains(action) }
    /// Whether the library has it switched on, and whether a switch is offered at all.
    var canSwitch: Bool { can("enable") || can("disable") }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle) || (title?.localizedCaseInsensitiveContains(needle) ?? false) || (description?.localizedCaseInsensitiveContains(needle) ?? false)
    }
}

/// `GET /api/skillshare/library`: everything a screen shows.
struct HerdrLibrary: Decodable, Sendable, Equatable {
    /// How many of each kind; nil for a kind that could not be read.
    struct Counts: Decodable, Sendable, Equatable {
        var skills: Int? = nil, agents: Int? = nil, mcp: Int? = nil, plugins: Int? = nil, hooks: Int? = nil
        subscript(kind: HerdrLibraryKind) -> Int? {
            switch kind { case .skills: skills; case .agents: agents; case .mcp: mcp; case .plugins: plugins; case .hooks: hooks }
        }
    }
    /// One agent program's folders and settings the library is brought into.
    struct Target: Decodable, Sendable, Equatable, Identifiable {
        var name: String
        var path: String? = nil
        var mode: String? = nil
        var status: String? = nil
        var linked: Int? = nil
        var skillsEnabled: Bool? = nil
        /// How many things wait for a sync to this Target.
        var waiting: Int? = nil
        var id: String { name }
        enum CodingKeys: CodingKey { case name, path, mode, status, linked, skillsEnabled, waiting }
        init(name: String, linked: Int? = nil, waiting: Int? = 0, status: String? = "merged") { self.name = name; self.linked = linked; self.waiting = waiting; self.status = status; skillsEnabled = true }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            path = try? c.decodeIfPresent(String.self, forKey: .path); mode = try? c.decodeIfPresent(String.self, forKey: .mode)
            status = try? c.decodeIfPresent(String.self, forKey: .status); linked = try? c.decodeIfPresent(Int.self, forKey: .linked)
            skillsEnabled = try? c.decodeIfPresent(Bool.self, forKey: .skillsEnabled); waiting = try? c.decodeIfPresent(Int.self, forKey: .waiting)
        }
    }
    /// A part of the answer that could not be read, and why: `list`, `diff`, `status`, `mcp`, `plugins` or `hooks`.
    struct Unread: Decodable, Sendable, Equatable {
        var part: String
        var reason: String? = nil
        enum CodingKeys: CodingKey { case part, problem, why, reason, error, message }
        init(part: String, reason: String? = nil) { self.part = part; self.reason = reason }
        init(from decoder: Decoder) throws {
            // A bare name is read too, in case the workspace sends the parts as words.
            if let word = try? decoder.singleValueContainer().decode(String.self) { part = word; return }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            part = (try? c.decodeIfPresent(String.self, forKey: .part)) ?? ""
            for key in [CodingKeys.problem, .why, .reason, .error, .message] {
                if let said = try? c.decodeIfPresent(String.self, forKey: key), !said.isEmpty { reason = said; break }
            }
        }
    }

    var installed: Bool = false
    var version: String? = nil
    /// Why the rest is missing or may be incomplete, in the server's words; nil when all is well.
    var problem: String? = nil
    /// `global`, or `project` with the folder in `project`.
    var scope: String? = nil
    var project: String? = nil
    /// The folder skillshare keeps the library in.
    var source: String? = nil
    var counts = Counts()
    /// Every thing in the library; `items` holds the first 1,000.
    var itemCount: Int? = nil
    var items: [HerdrLibraryItem] = []
    var targets: [Target] = []
    /// How many things wait for a sync.
    var waiting: Int? = nil
    /// A sentence when skillshare would refuse a sync of everything.
    var syncBlocked: String? = nil
    var unread: [Unread] = []
    /// When updates were last checked, in seconds since 1970; nil when not since the workspace started.
    var updatesChecked: Double? = nil

    enum CodingKeys: CodingKey { case installed, version, problem, scope, project, source, counts, itemCount, items, targets, waiting, syncBlocked, unread, updatesChecked }
    init(installed: Bool = true, version: String? = nil, problem: String? = nil, project: String? = nil, source: String? = nil, items: [HerdrLibraryItem] = [], targets: [Target] = [],
         syncBlocked: String? = nil, unread: [Unread] = [], updatesChecked: Double? = nil) {
        self.installed = installed; self.version = version; self.problem = problem; self.project = project; scope = project == nil ? "global" : "project"; self.source = source
        self.items = items; self.targets = targets; self.syncBlocked = syncBlocked; self.unread = unread; self.updatesChecked = updatesChecked
        itemCount = items.count; waiting = items.filter { $0.state == .waiting }.count
        func read(_ kind: HerdrLibraryKind) -> Int? { unread.contains { $0.part == kind.rawValue } ? nil : items.filter { $0.known == kind }.count }
        counts = Counts(skills: unread.contains { $0.part == "list" } ? nil : read(.skills), agents: read(.agents), mcp: read(.mcp), plugins: read(.plugins), hooks: read(.hooks))
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installed = (try? c.decodeIfPresent(Bool.self, forKey: .installed)) ?? false
        version = try? c.decodeIfPresent(String.self, forKey: .version); problem = try? c.decodeIfPresent(String.self, forKey: .problem)
        scope = try? c.decodeIfPresent(String.self, forKey: .scope); project = try? c.decodeIfPresent(String.self, forKey: .project)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        items = (try? c.decodeIfPresent([HerdrLibraryItem].self, forKey: .items)) ?? []
        targets = (try? c.decodeIfPresent([Target].self, forKey: .targets)) ?? []
        unread = (try? c.decodeIfPresent([Unread].self, forKey: .unread)) ?? []
        itemCount = try? c.decodeIfPresent(Int.self, forKey: .itemCount); waiting = try? c.decodeIfPresent(Int.self, forKey: .waiting)
        syncBlocked = try? c.decodeIfPresent(String.self, forKey: .syncBlocked); updatesChecked = try? c.decodeIfPresent(Double.self, forKey: .updatesChecked)
        if let sent = try? c.decodeIfPresent(Counts.self, forKey: .counts) { counts = sent }
        else { counts = Counts(skills: count(.skills), agents: count(.agents), mcp: count(.mcp), plugins: count(.plugins), hooks: count(.hooks)) }
    }
    private func count(_ kind: HerdrLibraryKind) -> Int { items.filter { $0.known == kind }.count }

    // MARK: What a screen works out

    /// Every thing the library has, by the server's own count.
    var total: Int { max(itemCount ?? 0, items.count) }
    /// More things than one answer carries.
    var hiddenCount: Int { max(0, total - items.count) }
    /// The things a sync would bring somewhere.
    var waitingCount: Int { max(waiting ?? 0, items.filter { $0.state == .waiting }.count) }
    /// The Targets a sync would change.
    var waitingTargets: [Target] {
        let named = Set(items.flatMap { $0.state == .waiting ? $0.waiting.map(\.target) : [] })
        return targets.filter { ($0.waiting ?? 0) > 0 || named.contains($0.name) }
    }
    var updates: [HerdrLibraryItem] { items.filter { $0.state == .update } }
    /// The ones an Update button can update.
    var updatable: [HerdrLibraryItem] { updates.filter { $0.can("update") } }
    func item(_ id: String) -> HerdrLibraryItem? { items.first { $0.id == id } }
    func items(of kind: HerdrLibraryKind?) -> [HerdrLibraryItem] { kind.map { kind in items.filter { $0.known == kind } } ?? items }
    /// What a filter tile says: the server's count, or the listed ones when it sent none; nil when that kind could not be read.
    func count(of kind: HerdrLibraryKind) -> Int? {
        if unread.contains(where: { $0.part == kind.rawValue || (kind == .skills && $0.part == "list") }), counts[kind] == nil { return nil }
        return counts[kind] ?? count(kind)
    }

    /// Where the library stands as a whole. Nothing here says "in sync" while a part could not be read.
    enum Standing: Equatable, Sendable {
        /// skillshare is missing or not set up, with the server's sentence.
        case missing(String)
        case empty
        /// Nothing is brought anywhere: the library has no Target.
        case noTargets
        /// skillshare would refuse a sync of everything, with its sentence.
        case blocked(String)
        case needsSync(things: Int, targets: [String])
        /// Nothing is known to wait, but these parts could not be read.
        case partUnread([Unread])
        /// Nothing is known to wait, but the server says that what it read may be incomplete, in its sentence.
        case unsure(String)
        case inSync(things: Int, targets: Int)
    }
    var standing: Standing {
        if !installed { return .missing(problem ?? HerdrLibraryCopy.notInstalled) }
        if items.isEmpty, unread.isEmpty, let problem, !problem.isEmpty { return .missing(problem) }
        if let syncBlocked, !syncBlocked.isEmpty { return .blocked(syncBlocked) }
        if waitingCount > 0 { return .needsSync(things: waitingCount, targets: waitingTargets.map(\.name)) }
        if !unread.isEmpty { return .partUnread(unread) }
        if let problem, !problem.isEmpty { return .unsure(problem) }
        if total == 0 { return .empty }
        if targets.isEmpty { return .noTargets }
        return .inSync(things: total, targets: targets.count)
    }
    /// The server's sentence about a library that is there but may be incomplete; nil when the headline already is that sentence.
    var note: String? {
        guard installed, let problem, !problem.isEmpty else { return nil }
        switch standing { case .missing, .unsure: return nil; default: return problem }
    }
    /// One press of Sync would do something, and skillshare would let it.
    var canSync: Bool { installed && (syncBlocked ?? "").isEmpty && !targets.isEmpty }

    /// The groups of the Library area, in the order they show.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case needsSync, update, inSync, off, unknown
        var id: String { rawValue }
        var title: String {
            switch self { case .needsSync: "Needs sync"; case .update: "Update available"; case .inSync: "In sync"; case .off: "Off"; case .unknown: "Could not be checked" }
        }
        init(_ state: HerdrLibraryItem.State) {
            switch state { case .waiting: self = .needsSync; case .update: self = .update; case .inSync: self = .inSync; case .off: self = .off; case .unknown: self = .unknown }
        }
    }
    /// The things of `kind` (nil: every kind) that match `query`, grouped by where they stand; empty groups are left out.
    func groups(kind: HerdrLibraryKind? = nil, query: String = "") -> [(group: Group, items: [HerdrLibraryItem])] {
        let shown = items(of: kind).filter { $0.matches(query) }
        return Group.allCases.compactMap { group in
            let members = shown.filter { Group($0.state) == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// Updates were never checked since the workspace started, or longer ago than `after` seconds: the library
    /// checks by itself when it opens.
    func needsUpdateCheck(now: Date = Date(), after seconds: TimeInterval = HerdrLibraryCopy.updateCheckEvery) -> Bool {
        guard installed, let checked = updatesChecked else { return installed }
        return now.timeIntervalSince1970 - checked > seconds
    }
}

/// What a change answered with: the library afterwards and what the route says it did (`enable`, `disable`, `check`,
/// `install`, `update`, `uninstall`). A field a route does not send stays nil.
struct HerdrLibraryAnswer: Decodable, Sendable, Equatable {
    var library: HerdrLibrary? = nil
    /// `enable`, `disable`: the ids whose state changed; empty when the thing already was as asked.
    var changed: [String]? = nil
    /// `check`: how many things have a newer version.
    var updates: Int? = nil
    /// `install`: the skills that were installed, and whether they stay at the checked version.
    var installed: [String]? = nil
    var pinned: Bool? = nil
    /// `update`: how many were updated, and what skillshare's audit refused to update.
    var updated: Int? = nil
    var blocked: [String]? = nil
    /// `uninstall`: what went to skillshare's trash.
    var removed: [String]? = nil
    var output: String? = nil
    var problem: String? = nil
}

/// What a sync of everything did (`POST /api/skillshare/sync` with `all`).
struct HerdrLibrarySynced: Decodable, Sendable, Equatable {
    var dryRun: Bool? = nil
    var linked: Int? = nil, local: Int? = nil, updated: Int? = nil, pruned: Int? = nil, ignored: Int? = nil
    var targets: [HerdrLibrary.Target]? = nil
    var output: String? = nil
    var library: HerdrLibrary? = nil
    var problem: String? = nil
}

/// `GET /api/skillshare/preview`: what there is to read about one thing.
struct HerdrLibraryPreview: Decodable, Sendable, Equatable {
    struct Fact: Decodable, Sendable, Equatable, Identifiable {
        var key: String
        var value = HerdrLooseValue([])
        /// The value holds names only: the real values stay on the server.
        var hidden = false
        var id: String { key + "\u{1}" + value.text }
        enum CodingKeys: CodingKey { case key, value, hidden }
        init(key: String, _ parts: [String], hidden: Bool = false) { self.key = key; value = HerdrLooseValue(parts); self.hidden = hidden }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
            value = (try? c.decodeIfPresent(HerdrLooseValue.self, forKey: .value)) ?? HerdrLooseValue([])
            hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        }
    }
    /// One Target the thing goes to: `waiting` (with what a sync would do), `in_sync` or `off`.
    struct Place: Decodable, Sendable, Equatable, Identifiable {
        var name: String
        var state: String? = nil
        var action: String? = nil
        var id: String { name }
        init(name: String, state: String? = "in_sync", action: String? = nil) { self.name = name; self.state = state; self.action = action }
    }

    var id: String = ""
    var kind: String = ""
    var name: String = ""
    var folder: String? = nil
    /// A skill's files (at most 200 names; `fileCount` counts them all) and the one that was read.
    var files: [String] = []
    var fileCount: Int? = nil
    var file: String? = nil
    /// A Markdown file's front matter, and the rest as `text` (the first 60,000 bytes; nil for a file that is not text).
    var meta: [Fact] = []
    var text: String? = nil
    var truncated = false
    /// MCP servers, plugins and hooks have no files; they have settings.
    var settings: [Fact] = []
    var targets: [Place] = []

    enum CodingKeys: CodingKey { case id, kind, name, folder, files, fileCount, file, meta, text, truncated, settings, targets }
    init(id: String, kind: HerdrLibraryKind, name: String, files: [String] = [], file: String? = nil, meta: [Fact] = [], text: String? = nil, truncated: Bool = false, settings: [Fact] = [], targets: [Place] = []) {
        self.id = id; self.kind = kind.rawValue; self.name = name; self.files = files; fileCount = files.count; self.file = file; self.meta = meta; self.text = text
        self.truncated = truncated; self.settings = settings; self.targets = targets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""; kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""; folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        files = (try? c.decodeIfPresent([String].self, forKey: .files)) ?? []; fileCount = try? c.decodeIfPresent(Int.self, forKey: .fileCount)
        file = try? c.decodeIfPresent(String.self, forKey: .file); meta = (try? c.decodeIfPresent([Fact].self, forKey: .meta)) ?? []
        text = try? c.decodeIfPresent(String.self, forKey: .text); truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        settings = (try? c.decodeIfPresent([Fact].self, forKey: .settings)) ?? []; targets = (try? c.decodeIfPresent([Place].self, forKey: .targets)) ?? []
    }

    var known: HerdrLibraryKind? { HerdrLibraryKind(rawValue: kind) }
    /// The file that was read is Markdown, so it shows as a page and not as plain text.
    var isMarkdown: Bool { (file ?? "").lowercased().hasSuffix(".md") }
    var hiddenFiles: Int { max(0, (fileCount ?? files.count) - files.count) }
    /// The front matter without what the header already shows.
    var facts: [Fact] { meta.filter { $0.key != "name" && $0.key != "description" && !$0.value.isEmpty } }
}

/// `GET /api/skillshare/diff`: what a sync would change, or what was edited in one skill, as skillshare prints it.
struct HerdrLibraryDiff: Decodable, Sendable, Equatable {
    var id: String? = nil
    var title: String? = nil
    var text: String? = nil
}

/// `POST /api/skillshare/install/inspect`: the skills a repository holds and what the audit says about each. Nothing
/// is installed by it; the download waits under `ticket` for 15 minutes.
struct HerdrInstallInspection: Decodable, Sendable, Equatable {
    struct Finding: Decodable, Sendable, Equatable, Identifiable {
        var severity: String? = nil
        var pattern: String? = nil
        var message: String? = nil
        var file: String? = nil
        var line: Int? = nil
        var snippet: String? = nil
        var id: String { [severity, pattern, file, line.map(String.init), snippet].map { $0 ?? "" }.joined(separator: "\u{1}") }
        /// "SKILL.md, line 7".
        var place: String? {
            guard let file, !file.isEmpty else { return nil }
            return line.map { "\(file), line \($0)" } ?? file
        }
    }
    struct Found: Decodable, Sendable, Equatable, Identifiable {
        var name: String
        var path: String? = nil
        var description: String? = nil
        /// The library already has one by this name: installing replaces it.
        var installed = false
        /// False when the workspace could not audit it in its download; skillshare still audits it when it installs.
        var audited = true
        var blocked = false
        var risk: String? = nil
        var score: Int? = nil
        var findings: [Finding] = []
        var id: String { path ?? name }
        enum CodingKeys: CodingKey { case name, path, description, installed, audited, blocked, risk, score, findings }
        init(name: String, description: String? = nil, installed: Bool = false, audited: Bool = true, blocked: Bool = false, risk: String? = "clean", score: Int? = 0, findings: [Finding] = []) {
            self.name = name; path = name; self.description = description; self.installed = installed; self.audited = audited; self.blocked = blocked; self.risk = risk; self.score = score; self.findings = findings
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""; path = try? c.decodeIfPresent(String.self, forKey: .path)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            installed = (try? c.decodeIfPresent(Bool.self, forKey: .installed)) ?? false; audited = (try? c.decodeIfPresent(Bool.self, forKey: .audited)) ?? true
            blocked = (try? c.decodeIfPresent(Bool.self, forKey: .blocked)) ?? false; risk = try? c.decodeIfPresent(String.self, forKey: .risk)
            score = try? c.decodeIfPresent(Int.self, forKey: .score); findings = (try? c.decodeIfPresent([Finding].self, forKey: .findings)) ?? []
        }
    }

    var ticket: String = ""
    var source: String? = nil
    var commit: String? = nil
    var expiresIn: Int? = nil
    /// The severity from which the audit blocks, such as `CRITICAL`.
    var threshold: String? = nil
    var skills: [Found] = []
    var blocked: [String] = []

    enum CodingKeys: CodingKey { case ticket, source, commit, expiresIn, threshold, skills, blocked }
    init(ticket: String, source: String? = nil, commit: String? = nil, threshold: String? = "CRITICAL", skills: [Found]) {
        self.ticket = ticket; self.source = source; self.commit = commit; self.threshold = threshold; self.skills = skills; blocked = skills.filter(\.blocked).map(\.name); expiresIn = 900
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticket = (try? c.decodeIfPresent(String.self, forKey: .ticket)) ?? ""; source = try? c.decodeIfPresent(String.self, forKey: .source)
        commit = try? c.decodeIfPresent(String.self, forKey: .commit); expiresIn = try? c.decodeIfPresent(Int.self, forKey: .expiresIn)
        threshold = try? c.decodeIfPresent(String.self, forKey: .threshold); skills = (try? c.decodeIfPresent([Found].self, forKey: .skills)) ?? []
        blocked = (try? c.decodeIfPresent([String].self, forKey: .blocked)) ?? []
    }

    /// Whether the audit blocks this skill: its own word, or its name in the answer's list.
    func isBlocked(_ skill: Found) -> Bool { skill.blocked || blocked.contains(skill.name) }
    /// What is ticked when the list first shows: everything that passed.
    var passed: [Found] { skills.filter { !isBlocked($0) } }
    /// The first twelve characters of the checked commit, as Git shows one.
    var shortCommit: String? { commit.map { String($0.prefix(12)) } }
}

/// `GET /api/skillshare/source`: the Git repository the library is in.
struct HerdrLibrarySource: Decodable, Sendable, Equatable {
    struct File: Decodable, Sendable, Equatable, Identifiable {
        var code: String? = nil
        var path: String = ""
        var id: String { path }
    }
    /// False: the library is not in a Git repository.
    var repo = false
    var folder: String? = nil
    var branch: String? = nil
    var upstream: String? = nil
    /// Where it pushes to, without a password or token.
    var remote: String? = nil
    /// Commits not pushed yet, commits not pulled yet, and what is not committed (at most 200; `fileCount` counts all).
    var ahead: Int? = nil
    var behind: Int? = nil
    var files: [File] = []
    var fileCount: Int? = nil
    var problem: String? = nil

    enum CodingKeys: CodingKey { case repo, folder, branch, upstream, remote, ahead, behind, files, fileCount, problem }
    init(repo: Bool = true, branch: String? = "main", remote: String? = nil, ahead: Int = 0, behind: Int = 0, changed: Int = 0, problem: String? = nil) {
        self.repo = repo; self.branch = branch; upstream = remote == nil ? nil : "origin/\(branch ?? "main")"; self.remote = remote; self.ahead = ahead; self.behind = behind
        fileCount = changed; files = (0..<min(changed, 200)).map { File(code: "M", path: "file-\($0)") }; self.problem = problem
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = (try? c.decodeIfPresent(Bool.self, forKey: .repo)) ?? false; folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        branch = try? c.decodeIfPresent(String.self, forKey: .branch); upstream = try? c.decodeIfPresent(String.self, forKey: .upstream)
        remote = try? c.decodeIfPresent(String.self, forKey: .remote); ahead = try? c.decodeIfPresent(Int.self, forKey: .ahead); behind = try? c.decodeIfPresent(Int.self, forKey: .behind)
        files = (try? c.decodeIfPresent([File].self, forKey: .files)) ?? []; fileCount = try? c.decodeIfPresent(Int.self, forKey: .fileCount)
        problem = try? c.decodeIfPresent(String.self, forKey: .problem)
    }

    /// Files changed on the server and not committed.
    var unsaved: Int { max(fileCount ?? 0, files.count) }
    var hasRemote: Bool { !(remote ?? "").isEmpty || !(upstream ?? "").isEmpty }
    var toPush: Int { ahead ?? 0 }
    var toPull: Int { behind ?? 0 }
    /// Nothing to save, push or pull.
    var isUpToDate: Bool { repo && unsaved == 0 && toPush == 0 && toPull == 0 }
}

/// What a pull, a push or a sync of the repository answered with; `conflict` when the server and the remote changed
/// the same file, and then nothing was changed.
struct HerdrSourceAnswer: Decodable, Sendable, Equatable {
    struct Conflict: Decodable, Sendable, Equatable {
        struct File: Decodable, Sendable, Equatable, Identifiable {
            var path: String = ""
            /// The file as this server has it and as the remote has it; nil when that side deleted it.
            var mine: String? = nil
            var theirs: String? = nil
            /// A side was longer than what was sent.
            var cut: Bool? = nil
            var id: String { path }
        }
        /// Whether resolving should push afterwards, as the request that met the conflict would have.
        var push: Bool? = nil
        var files: [File] = []
        enum CodingKeys: CodingKey { case push, files }
        init(push: Bool, files: [File]) { self.push = push; self.files = files }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            push = try? c.decodeIfPresent(Bool.self, forKey: .push); files = (try? c.decodeIfPresent([File].self, forKey: .files)) ?? []
        }
    }
    var source: HerdrLibrarySource? = nil
    var library: HerdrLibrary? = nil
    var output: String? = nil
    var conflict: Conflict? = nil
}

/// `GET /api/skillshare/machine`: skillshare on one server.
struct HerdrLibraryMachine: Decodable, Sendable, Equatable {
    struct Doctor: Decodable, Sendable, Equatable {
        struct Note: Decodable, Sendable, Equatable, Identifiable {
            var status: String? = nil
            var name: String? = nil
            var message: String? = nil
            var details: [String]? = nil
            var id: String { (name ?? "") + "\u{1}" + (message ?? "") }
        }
        var errors: Int? = nil
        var warnings: Int? = nil
        var notes: [Note]? = nil
    }
    var installed = false
    var version: String? = nil
    /// Filled only when the workspace was asked to look for skillshare's newest release.
    var latest: String? = nil
    var updateAvailable: Bool? = nil
    /// What the server calls itself.
    var host: String? = nil
    var problem: String? = nil
    var source: HerdrLibrarySource? = nil
    var targets: [HerdrLibrary.Target] = []
    var waiting: Int? = nil
    var doctor: Doctor? = nil

    enum CodingKeys: CodingKey { case installed, version, latest, updateAvailable, host, problem, source, targets, waiting, doctor }
    init(installed: Bool = true, version: String? = nil, latest: String? = nil, updateAvailable: Bool? = nil, host: String? = nil, problem: String? = nil, source: HerdrLibrarySource? = nil,
         targets: [HerdrLibrary.Target] = [], waiting: Int? = 0, doctor: Doctor? = nil) {
        self.installed = installed; self.version = version; self.latest = latest; self.updateAvailable = updateAvailable; self.host = host; self.problem = problem
        self.source = source; self.targets = targets; self.waiting = waiting; self.doctor = doctor
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installed = (try? c.decodeIfPresent(Bool.self, forKey: .installed)) ?? false; version = try? c.decodeIfPresent(String.self, forKey: .version)
        latest = try? c.decodeIfPresent(String.self, forKey: .latest); updateAvailable = try? c.decodeIfPresent(Bool.self, forKey: .updateAvailable)
        host = try? c.decodeIfPresent(String.self, forKey: .host); problem = try? c.decodeIfPresent(String.self, forKey: .problem)
        source = try? c.decodeIfPresent(HerdrLibrarySource.self, forKey: .source); targets = (try? c.decodeIfPresent([HerdrLibrary.Target].self, forKey: .targets)) ?? []
        waiting = try? c.decodeIfPresent(Int.self, forKey: .waiting); doctor = try? c.decodeIfPresent(Doctor.self, forKey: .doctor)
    }

    /// What `skillshare doctor` warns about, errors first, each in its own sentence.
    var warnings: [Doctor.Note] {
        let notes = (doctor?.notes ?? []).filter { ($0.status ?? "") != "ok" && ($0.status ?? "") != "pass" && !($0.message ?? "").isEmpty }
        return notes.filter { $0.status == "error" } + notes.filter { $0.status != "error" }
    }
    var waitingCount: Int { max(waiting ?? 0, targets.map { $0.waiting ?? 0 }.max() ?? 0) }
}

/// `POST /api/skillshare/upgrade`: the version skillshare has afterwards.
struct HerdrSkillshareUpgraded: Decodable, Sendable, Equatable {
    var version: String? = nil
    var output: String? = nil
}

/// `GET /api/skillshare/projects`: which folders hold a skillshare project: the folder the server's bots work in,
/// which the server asks about by itself, and the asked ones.
struct HerdrSkillshareProjects: Decodable, Sendable, Equatable {
    struct Project: Decodable, Sendable, Equatable, Identifiable {
        var folder: String = ""
        var config: String? = nil
        /// The folder the server's bots work in, which the server names itself.
        var bots: Bool? = nil
        var id: String { folder }
    }
    var projects: [Project] = []
    enum CodingKeys: CodingKey { case projects }
    init(projects: [Project] = []) { self.projects = projects }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? c.decodeIfPresent([Project].self, forKey: .projects)) ?? []
    }
}

/// A request the workspace refused: its own sentence, to show as it is, and what a refused install names.
struct HerdrLibraryRefusal: LocalizedError, Equatable, Sendable {
    let status: Int
    let message: String
    /// 409 on an install: the chosen skills the audit blocks, or the ones the library already has.
    var blocked: [String] = []
    var installed: [String] = []
    var errorDescription: String? { message }

    private struct Body: Decodable { var error: String? = nil; var problem: String? = nil; var blocked: [String]? = nil; var installed: [String]? = nil }

    /// What a status other than 2xx means for these routes. A workspace without them answers 404 with no sentence
    /// of its own: it is older.
    static func of(status: Int, body: Data) -> HerdrLibraryRefusal {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let said = try? decoder.decode(Body.self, from: body)
        guard let message = said?.error ?? said?.problem, !message.isEmpty else {
            return HerdrLibraryRefusal(status: status, message: status == 404 ? HerdrLibraryCopy.olderService : "The server answered HTTP \(status).")
        }
        return HerdrLibraryRefusal(status: status, message: message, blocked: said?.blocked ?? [], installed: said?.installed ?? [])
    }
}

/// Which of a bot's projects could have a library of their own: the ones on the server the workspace itself runs
/// on. A project names a project server; that server is the Herdr server itself when it calls itself by the same
/// host name, or when its address is the server's own loopback.
enum HerdrLibraryScope {
    /// One choice of scope: a project's name and its folder on the server.
    struct Choice: Equatable, Sendable, Identifiable {
        var name: String
        var folder: String
        /// The folder the server's bots work in, not one of the bot's projects.
        var botsFolder = false
        var id: String { folder }
    }
    /// A project as this needs it, and the server it is on (the name, what that machine calls itself, and how ssh reaches it).
    struct Candidate: Equatable, Sendable { var name: String; var folder: String; var machineHost: String?; var machineTarget: String }

    static func isServerItself(machineHost: String?, machineTarget: String, host: String?) -> Bool {
        // "deploy@10.0.0.7:2222" and "[::1]:22": the part ssh takes as the host.
        var address = (machineTarget.split(separator: "@").last.map(String.init) ?? machineTarget).lowercased()
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") { address = String(address[address.index(after: address.startIndex)..<end]) }
        else if address.filter({ $0 == ":" }).count == 1 { address = String(address.split(separator: ":")[0]) }
        if ["localhost", "127.0.0.1", "::1"].contains(address) { return true }
        func short(_ name: String?) -> String { (name ?? "").lowercased().split(separator: ".").first.map(String.init) ?? "" }
        let own = short(host)
        return !own.isEmpty && short(machineHost) == own
    }

    /// The folders to ask the workspace about: the bot's projects that are on the server itself, each once.
    static func local(_ candidates: [Candidate], host: String?) -> [Choice] {
        var found: [Choice] = []
        for candidate in candidates where isServerItself(machineHost: candidate.machineHost, machineTarget: candidate.machineTarget, host: host) {
            if candidate.folder.hasPrefix("/"), !found.contains(where: { $0.folder == candidate.folder }) { found.append(Choice(name: candidate.name, folder: candidate.folder)) }
        }
        return found
    }
}
