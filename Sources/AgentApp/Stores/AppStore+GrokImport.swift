import Foundation

struct GrokImportRow: Equatable {
    var name: String; var profile: String?; var historyCount: Int; var avatar: BotAvatarName; var accent: String?
    var sourceShape: String?; var sourceColour: String?; var isGroup: Bool; var created: Bool
}

extension AppStore {
    static let grokHermesBaseURL = "https://konrad.agenthut.net/v1"

    /// Keychain account for a bot's Hermes key (`hermes` for the default profile).
    static func keyAccount(forProfile profile: String) -> String { profile == "default" ? "hermes" : "hermes.\(profile)" }

    /// A Hermes bot bound to a named profile whose Keychain key is missing shows "Add key" instead of
    /// sending (and erroring). Injected test backends bypass the check.
    func needsKey(_ bot: Bot) -> Bool {
        guard backendFactory == nil, bot.backend == .hermes, let profile = bot.hermesProfile, profile != "default" else { return false }
        return keyStore.key(for: Self.keyAccount(forProfile: profile)).isEmpty
    }

    func saveKey(_ key: String, for bot: Bot) {
        guard let profile = bot.hermesProfile, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyStore.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyAccount(forProfile: profile))
        objectWillChange.send()
    }

    /// Imports (or re-imports) Grok Bot bundles. Bots are matched by `source_id`, then by an unclaimed bot
    /// on the same Hermes profile, so repeated imports never duplicate bots or history lines.
    @discardableResult func importGrokBundles(_ bundles: [GrokBotBundle]) throws -> [GrokImportRow] {
        let clean = { (text: String) in GrokTemplateParser.redactSecrets(text, replacement: "[REDACTED]").text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var rows: [GrokImportRow] = []
        migrateArchivedGroups()
        // Bots first, so a group's members resolve to the bots imported in this run.
        for bundle in bundles.filter({ !($0.isGroup ?? false) }) + bundles.filter({ $0.isGroup ?? false }) {
            if bundle.isGroup ?? false { rows.append(try importGrokGroup(bundle, clean: clean)); continue }
            let profile = [bundle.profile, bundle.slug.map { "grok-\($0)" }].compactMap { $0 }.first(where: HermesKeyPaste.isValidProfileName)
            let existing = bots.first { $0.grokSourceID == bundle.sourceId }
                ?? profile.flatMap { profile in bots.first { $0.grokSourceID == nil && $0.backend == .hermes && $0.hermesProfile == profile } }
            let bot = existing ?? Bot(name: "")
            let mapped = GrokAvatarMap.map(shape: bundle.avatar?.shape, colour: bundle.avatar?.colour, sourceID: bundle.sourceId)
            let description = clean(bundle.description ?? "")
            bot.name = clean(bundle.name).isEmpty ? "Grok bot" : clean(bundle.name)
            bot.title = clean(bundle.title ?? "").isEmpty ? "Imported from Grok Bot" : clean(bundle.title ?? "")
            bot.botDescription = description
            let instructions = clean(bundle.instructions ?? description)
            if !instructions.isEmpty { bot.persona = instructions }
            bot.avatarName = mapped.avatar; bot.accentColor = mapped.accent; bot.grokSourceID = bundle.sourceId
            bot.backend = .hermes; bot.hermesProfile = profile; bot.hermesBaseURL = Self.grokHermesBaseURL; bot.archivedMembers = nil
            bot.isDemo = false
            bot.grokHistoryCount = try grokHistory.merge(ArchivedMessage.from(bundle), sourceID: bundle.sourceId, for: bot.id)
            if existing == nil { bots.append(bot) }
            rows.append(.init(name: bot.name, profile: bot.hermesProfile, historyCount: bot.grokHistoryCount, avatar: mapped.avatar, accent: mapped.accent,
                              sourceShape: bundle.avatar?.shape, sourceColour: bundle.avatar?.colour, isGroup: false, created: existing == nil))
        }
        // The demo bots step aside once real bots exist; they stay under Hidden chats.
        if !rows.isEmpty { bots.filter(\.isDemo).forEach { $0.isHidden = true } }
        if selectedBot == nil || selectedBot?.isHidden == true { selectedBot = bots.first { !$0.isHidden } }
        objectWillChange.send(); save()
        return rows
    }

    /// A Grok group becomes a P5 group (matched by `source_id`); members are set when it is first created,
    /// so later re-imports keep membership edits. Its history is the group's read-only archive.
    private func importGrokGroup(_ bundle: GrokBotBundle, clean: (String) -> String) throws -> GrokImportRow {
        let existing = groups.first { $0.grokSourceID == bundle.sourceId }
        let group = existing ?? GroupChat(name: "", memberIDs: resolveMembers((bundle.members ?? []).map { (clean($0.name), $0.sourceId) }))
        group.name = clean(bundle.name).isEmpty ? defaultGroupName(group.memberIDs) : clean(bundle.name)
        group.grokSourceID = bundle.sourceId
        group.grokHistoryCount = try grokHistory.merge(ArchivedMessage.from(bundle), sourceID: bundle.sourceId, for: group.id)
        if existing == nil { groups.append(group) }
        let mapped = GrokAvatarMap.map(shape: bundle.avatar?.shape, colour: bundle.avatar?.colour, sourceID: bundle.sourceId)
        return GrokImportRow(name: group.name, profile: nil, historyCount: group.grokHistoryCount, avatar: mapped.avatar, accent: mapped.accent,
                             sourceShape: bundle.avatar?.shape, sourceColour: bundle.avatar?.colour, isGroup: true, created: existing == nil)
    }

    @discardableResult func importGrokExport(at url: URL) throws -> [GrokImportRow] {
        try importGrokBundles(GrokBundleLoader.load(from: url))
    }
}
