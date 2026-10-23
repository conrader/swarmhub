import Foundation

struct GrokImportRow: Equatable {
    var name: String; var profile: String?; var historyCount: Int; var mark: AvatarMark
    var sourceShape: String?; var sourceColour: String?; var isGroup: Bool; var created: Bool
}

/// How an import treats bots that already exist (briefs/P10.md P10a 1).
enum GrokImportPolicy: Sendable, Equatable {
    /// `--import-grok` as since P6: every bot is (re)written from the bundle, on `grokHermesBaseURL`.
    case legacyFileImport
    /// The in-app flow: new bots take `serverURL` (the Settings server, nil when none is set); linked bots get history
    /// only unless `refreshIdentity`; profiles are bound by `grokBindingProfile`.
    case inApp(serverURL: String?, refreshIdentity: Bool)
}

enum GrokImportError: LocalizedError, Equatable {
    case persistenceDisabled
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .persistenceDisabled: "\(AppConstants.name) cannot save right now (its store could not be read at launch), so nothing was imported."
        case .saveFailed: "\(AppConstants.name) could not save its store after the import; the history archives were written but the bots were not saved."
        }
    }
}

extension AppStore {
    static let grokHermesBaseURL = "https://konrad.agenthut.net/v1"

    /// Keychain account for a bot's Hermes key (`hermes` for the default profile).
    static func keyAccount(forProfile profile: String) -> String { profile == "default" ? "hermes" : "hermes.\(profile)" }

    /// A Hermes bot bound to a named profile whose Keychain key is missing shows "Add key" instead of
    /// sending (and erroring), as does any Hermes bot whose stored key needs re-entry. Injected test backends bypass the check.
    func needsKey(_ bot: Bot) -> Bool {
        guard backendFactory == nil, bot.backend == .hermes else { return false }
        if keyNeedsReentry(bot) { return true }
        guard let profile = bot.hermesProfile, profile != "default" else { return false }
        return keyStore.key(for: Self.keyAccount(forProfile: profile)).isEmpty
    }

    /// This bot's stored key could not be read without a dialog and nothing replaced it this launch; no further read
    /// happens until the key is re-entered.
    func keyNeedsReentry(_ bot: Bot) -> Bool { bot.backend == .hermes && keyStore.needsReentry(Self.keyAccount(forProfile: bot.hermesProfile ?? "default")) }

    func saveKey(_ key: String, for bot: Bot) {
        let profile = bot.hermesProfile ?? "default"
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyStore.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyAccount(forProfile: profile))
        objectWillChange.send()
    }

    /// Imports (or re-imports) Grok Bot bundles. Bots are matched by `source_id`, then by an unclaimed bot
    /// on the same Hermes profile, so repeated imports never duplicate bots or history lines.
    @discardableResult func importGrokBundles(_ bundles: [GrokBotBundle],
                                              policy: GrokImportPolicy = .legacyFileImport) throws -> [GrokImportRow] {
        try beginGrokImport()
        var rows: [GrokImportRow] = []
        do {
            for prepared in Self.ordered(bundles).map(PreparedGrokBundle.init) {
                let target = grokTarget(for: prepared, policy: policy)
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
                                              timing: GrokImportTiming? = nil) async throws -> [GrokImportRow] {
        var stretch = timing?.start()
        try beginGrokImport()
        var rows: [GrokImportRow] = []
        do {
            for bundle in Self.ordered(bundles) {
                timing?.end(&stretch)
                let prepared = await Task.detached(priority: .userInitiated) { PreparedGrokBundle(bundle) }.value
                stretch = timing?.start()
                let target = grokTarget(for: prepared, policy: policy)
                timing?.end(&stretch)
                let count = try await grokHistory.mergeInBackground(prepared.lines, sourceID: prepared.bundle.sourceId, for: target.id)
                stretch = timing?.start()
                rows.append(apply(prepared, to: target, historyCount: count, policy: policy))
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

    /// Binds every Grok-imported Hermes bot that has no profile yet (fill-only: never replaces a profile).
    /// Returns the bots that were bound.
    @discardableResult func bindUnboundGrokBots() -> [Bot] {
        let serverSet = defaults.string(forKey: "hermesBaseURL") != nil
        var bound: [Bot] = []
        for bot in bots where bot.isGrokHistoryOnly {
            let slug = GrokNaming.profileSlug(bot.name)
            let candidates = Self.grokCandidates(profile: GrokNaming.profile(forName: bot.name), slug: slug.isEmpty ? nil : slug)
            guard let profile = grokBindingProfile(candidates, for: bot, serverSet: serverSet) else { continue }
            bot.hermesProfile = profile
            bound.append(bot)
        }
        if !bound.isEmpty { objectWillChange.send(); save() }
        return bound
    }

    /// The Settings server new in-app imported bots chat through; nil when none is set (they import history-only).
    var grokSettingsServerURL: String? { defaults.string(forKey: "hermesBaseURL") }

    /// Archive lines already kept for a Grok conversation (bot or group), 0 when it was never imported.
    func grokArchiveLines(sourceID: String) -> Int {
        bots.first { $0.grokSourceID == sourceID }?.grokHistoryCount ?? groups.first { $0.grokSourceID == sourceID }?.grokHistoryCount ?? 0
    }

    /// Writes `store.json`, surfacing a failure (the plain `save()` ignores it).
    func saveThrowing() throws {
        guard persistenceEnabled else { throw GrokImportError.persistenceDisabled }
        do { try JSONEncoder().encode(storeFile).write(to: fileURL, options: .atomic) }
        catch { throw GrokImportError.saveFailed }
    }

    // MARK: Steps

    /// Bots first, so a group's members resolve to the bots imported in this run.
    private static func ordered(_ bundles: [GrokBotBundle]) -> [GrokBotBundle] {
        bundles.filter { !($0.isGroup ?? false) } + bundles.filter { $0.isGroup ?? false }
    }

    private func beginGrokImport() throws {
        guard persistenceEnabled else { throw GrokImportError.persistenceDisabled }
        migrateArchivedGroups()
    }

    private func finishGrokImport(_ rows: [GrokImportRow]) throws {
        // The sample bots go once real bots exist (P35 D6); any left (no real bot yet) step aside under Hidden chats.
        if !rows.isEmpty { removeSampleBots(); bots.filter(\.isDemo).forEach { $0.isHidden = true } }
        if (selectedBot == nil && selectedGroup == nil && selectedBoxProfile == nil) || selectedBot?.isHidden == true { selectVisibleChat() }
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
    /// Inert config (`AppStore+GrokStaged.swift`): routine names, prompts and schedules through the filter, ids in the
    /// exported `grok-automation-` form (`GrokStagedConfig.safeRoutineID`); a connector whose name held a secret is left out.
    let routines: [GrokStagedRoutine]
    let connectors: [String]

    init(_ bundle: GrokBotBundle) {
        let clean = { (text: String) in
            SecretFilter.redacted(text, replacement: GrokRedactor.marker).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.bundle = bundle
        name = clean(bundle.name); title = clean(bundle.title ?? ""); description = clean(bundle.description ?? "")
        instructions = clean(bundle.instructions ?? bundle.description ?? "")
        members = (bundle.members ?? []).map { (clean($0.name), $0.sourceId) }
        lines = ArchivedMessage.from(bundle)
        routines = (bundle.routines ?? []).map { routine in
            let name = clean(routine.name), schedule = clean(routine.schedule ?? "")
            return GrokStagedRoutine(id: GrokStagedConfig.safeRoutineID(routine.id), name: name.isEmpty ? GrokStagedConfig.unnamedRoutine : name,
                                     prompt: clean(routine.prompt ?? ""), schedule: schedule)
        }
        connectors = (bundle.connectors ?? []).reduce(into: [String]()) { names, connector in
            guard SecretFilter.redacted(connector.name, replacement: GrokRedactor.marker) == connector.name else { return }
            let name = GrokStagedConfig.connectorName(connector.name)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
    }
}
