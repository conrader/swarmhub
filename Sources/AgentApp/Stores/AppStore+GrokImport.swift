import Foundation

struct GrokImportRow: Equatable {
    var name: String; var historyCount: Int; var mark: AvatarMark
    var sourceShape: String?; var sourceColour: String?; var isGroup: Bool; var created: Bool
}

/// How an import treats bots that already exist.
enum GrokImportPolicy: Sendable, Equatable {
    /// `--import-grok`: every bot is (re)written from the bundle.
    case fileImport
    /// The in-app flow: bots imported before get history only unless `refreshIdentity`.
    case inApp(refreshIdentity: Bool)
}

enum GrokImportError: LocalizedError, Equatable {
    case persistenceDisabled
    case saveFailed
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .persistenceDisabled: "\(AppConstants.name) cannot save right now (its store could not be read at launch), so nothing was imported."
        case .destinationUnavailable: "The tested import host is no longer available. Select and test it again."
        case .saveFailed: "\(AppConstants.name) could not save its store after the import; the history archives were written but the bots were not saved."
        }
    }
}

extension AppStore {
    /// Imports (or re-imports) Grok Bot bundles. Bots are matched by `source_id`, so repeated imports never
    /// duplicate bots or history lines.
    @discardableResult func importGrokBundles(_ bundles: [GrokBotBundle],
                                              policy: GrokImportPolicy = .fileImport) throws -> [GrokImportRow] {
        try beginGrokImport()
        var rows: [GrokImportRow] = []
        do {
            for prepared in Self.ordered(bundles).map(PreparedGrokBundle.init) {
                let target = grokTarget(for: prepared)
                let count = try grokHistory.merge(prepared.lines, sourceID: prepared.bundle.sourceId, for: target.id)
                rows.append(apply(prepared, to: target, historyCount: count, policy: policy))
            }
        } catch { try? finishGrokImport(rows); throw error }
        try finishGrokImport(rows)
        return rows
    }

    /// The same import with the redaction and archive work off the main actor, yielding between bundles.
    /// `timing` (tests) records how long each synchronous main-actor stretch of the import took.
    @discardableResult func importGrokBundles(_ bundles: [GrokBotBundle], policy: GrokImportPolicy,
                                              timing: GrokImportTiming? = nil, destination: GrokDestination? = nil,
                                              settledFetchedSequences: [String: Set<Int64>] = [:]) async throws -> [GrokImportRow] {
        var stretch = timing?.start()
        try beginGrokImport()
        var rows: [GrokImportRow] = []
        do {
            for bundle in Self.ordered(bundles) {
                timing?.end(&stretch)
                let prepared = await Task.detached(priority: .userInitiated) { PreparedGrokBundle(bundle) }.value
                stretch = timing?.start()
                try validateGrokDestination(destination)
                let target = grokTarget(for: prepared, destination: destination)
                timing?.end(&stretch)
                let sourceID = prepared.bundle.sourceId
                let count = try await grokHistory.mergeInBackground(prepared.lines, sourceID: sourceID, for: target.id,
                                                                    settledFetchedSequences: settledFetchedSequences[sourceID] ?? [])
                stretch = timing?.start()
                try validateGrokDestination(destination)
                rows.append(apply(prepared, to: target, historyCount: count, policy: policy, destination: destination))
                timing?.end(&stretch)
                await Task.yield()
                stretch = timing?.start()
            }
        } catch { try? finishGrokImport(rows); throw error }
        try finishGrokImport(rows)
        timing?.end(&stretch)
        return rows
    }

    @discardableResult func importGrokExport(at url: URL) throws -> [GrokImportRow] {
        try importGrokBundles(GrokBundleLoader.load(from: url))
    }

    /// Archive lines already kept for a Grok conversation (bot or group), 0 when it was never imported.
    func grokArchiveLines(sourceID: String) -> Int {
        bots.first { $0.grokSourceID == sourceID }?.grokHistoryCount ?? groups.first { $0.grokSourceID == sourceID }?.grokHistoryCount ?? 0
    }

    /// Writes `store.json`, surfacing a failure (the plain `save()` ignores it).
    func saveThrowing() throws {
        guard persistenceEnabled else { throw GrokImportError.persistenceDisabled }
        do {
            try writeStore()
        }
        catch { throw GrokImportError.saveFailed }
    }

    // MARK: Steps

    /// Bots first, so a group's members resolve to the bots imported in this run.
    private static func ordered(_ bundles: [GrokBotBundle]) -> [GrokBotBundle] {
        bundles.filter { !($0.isGroup ?? false) } + bundles.filter { $0.isGroup ?? false }
    }

    private func validateGrokDestination(_ destination: GrokDestination?) throws {
        guard let destination else { return }
        guard let host = herdrServer(id: destination.serverID),
              destination.testedHost.map({ $0 == host }) ?? true else { throw GrokImportError.destinationUnavailable }
    }

    private func beginGrokImport() throws {
        guard persistenceEnabled else { throw GrokImportError.persistenceDisabled }
        migrateArchivedGroups()
    }

    private func finishGrokImport(_ rows: [GrokImportRow]) throws {
        // The sample bots go once real bots exist (P35 D6); any left (no real bot yet) step aside under Hidden chats.
        if !rows.isEmpty { removeSampleBots(); bots.filter(\.isDemo).forEach { $0.isHidden = true } }
        if (selectedBot == nil && selectedGroup == nil) || selectedBot?.isHidden == true { selectVisibleChat() }
        objectWillChange.send()
        try saveThrowing()
    }
}

/// The main-actor stretches of one in-app import (P10a target: each one under 100 ms for a 3,000-message bot).
@MainActor final class GrokImportTiming {
    private let clock = ContinuousClock()
    private(set) var stretches: [Duration] = []
    var longest: Duration { stretches.max() ?? .zero }
    var total: Duration { stretches.reduce(.zero, +) }

    func start() -> ContinuousClock.Instant { clock.now }
    func end(_ start: inout ContinuousClock.Instant?) {
        if let begun = start { stretches.append(clock.now - begun) }
        start = nil
    }
}

/// A bundle with every text field through the secret filter and its archive lines built: pure, so it can run off the
/// main actor. The importer's second pass over already-redacted bundles is idempotent.
struct PreparedGrokBundle: Sendable {
    let bundle: GrokBotBundle
    let name: String, title: String, description: String, instructions: String
    let members: [(name: String, sourceID: String)]
    let lines: [ArchivedMessage]

    static func cleanIdentity(_ text: String) -> String {
        SecretFilter.redacted(text, replacement: GrokRedactor.marker).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func meaningful(_ value: String?) -> String {
        let text = cleanIdentity(value ?? "")
        let key = text.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
        let generic = ["a teammate with its own computer that takes real work off your plate",
                       "personal agent", "imported from grok bot", "grok bot",
                       "you are a thoughtful capable assistant"]
        return generic.contains(key) ? "" : text
    }

    init(_ bundle: GrokBotBundle) {
        let clean = Self.cleanIdentity
        self.bundle = bundle
        name = clean(bundle.name); title = Self.meaningful(bundle.title)
        let sourceDescription = Self.meaningful(bundle.description)
        let suppliedInstructions = Self.meaningful(bundle.instructions)
        description = !sourceDescription.isEmpty ? sourceDescription
            : (!title.isEmpty ? title : String(suppliedInstructions.prefix(300)))
        instructions = suppliedInstructions.isEmpty ? sourceDescription : suppliedInstructions
        members = (bundle.members ?? []).map { (clean($0.name), $0.sourceId) }
        lines = ArchivedMessage.from(bundle)
    }
}
