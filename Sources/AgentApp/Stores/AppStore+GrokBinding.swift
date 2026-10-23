import Foundation

extension Bot {
    /// A Grok-imported Hermes bot with no profile: its archive shows, but it never chats (and never falls through to
    /// the `127.0.0.1` default) until a profile is bound.
    var isGrokHistoryOnly: Bool { grokSourceID != nil && backend == .hermes && hermesProfile == nil && !isReadOnlyArchive }
}

/// Where one bundle lands: a group, or a bot that is already linked, adopted from an unclaimed Hermes bot, or new.
enum GrokImportTarget {
    enum Kind { case linked, adopted, new }
    case bot(Bot, Kind)
    case group(GroupChat, created: Bool)

    var id: UUID {
        switch self {
        case .bot(let bot, _): bot.id
        case .group(let group, _): group.id
        }
    }
}

extension AppStore {
    /// Profiles a bundle may bind to, in order: [`bundle.profile`, `grok-<slug>`, `<slug>`], valid names only. A bot
    /// bundle without a profile was left history-only by the builder (its profile is another bot's): no candidates.
    static func grokCandidates(_ bundle: GrokBotBundle) -> [String] {
        bundle.profile == nil ? [] : grokCandidates(profile: bundle.profile, slug: bundle.slug)
    }

    static func grokCandidates(profile: String?, slug: String?) -> [String] {
        var seen = Set<String>()
        return [profile, slug.map { "grok-\($0)" }, slug].compactMap { $0 }
            .filter { $0 != "default" && HermesKeyPaste.isValidProfileName($0) && seen.insert($0).inserted }
    }

    /// The first free candidate with a key in the key store (attributes only); else, when a Hermes server is set, the
    /// first free candidate (the "Add key" banner then asks for it); else none (history-only).
    func grokBindingProfile(_ candidates: [String], for bot: Bot, serverSet: Bool) -> String? {
        let used = Set(bots.filter { $0 !== bot && $0.backend == .hermes }.compactMap(\.hermesProfile))
        let free = candidates.filter { !used.contains($0) }
        if let keyed = free.first(where: { keyStore.hasKey(for: Self.keyAccount(forProfile: $0)) }) { return keyed }
        return serverSet ? free.first : nil
    }

    func grokTarget(for prepared: PreparedGrokBundle, policy: GrokImportPolicy) -> GrokImportTarget {
        let bundle = prepared.bundle
        if bundle.isGroup ?? false {
            if let existing = groups.first(where: { $0.grokSourceID == bundle.sourceId }) { return .group(existing, created: false) }
            return .group(GroupChat(name: "", memberIDs: resolveMembers(prepared.members)), created: true)
        }
        if let linked = bots.first(where: { $0.grokSourceID == bundle.sourceId }) { return .bot(linked, .linked) }
        let candidates: [String]
        switch policy {
        case .legacyFileImport:
            candidates = Self.legacyProfile(bundle).map { [$0] } ?? []
        case .inApp:
            candidates = Self.grokCandidates(bundle)
        }
        for candidate in candidates {
            if let unclaimed = bots.first(where: { $0.grokSourceID == nil && $0.backend == .hermes && $0.hermesProfile == candidate }) {
                return .bot(unclaimed, .adopted)
            }
        }
        return .bot(Bot(name: ""), .new)
    }

    /// Applies a bundle whose history is already merged (`historyCount`) to its target and returns the report row.
    func apply(_ prepared: PreparedGrokBundle, to target: GrokImportTarget, historyCount: Int, policy: GrokImportPolicy) -> GrokImportRow {
        let bundle = prepared.bundle
        let mapped = GrokAvatarMap.map(shape: bundle.avatar?.shape, colour: bundle.avatar?.colour, sourceID: bundle.sourceId)
        let refresh: Bool
        if case .inApp(_, let refreshIdentity) = policy { refresh = refreshIdentity } else { refresh = true }
        switch target {
        case .group(let group, let created):
            if created || refresh { group.name = prepared.name.isEmpty ? defaultGroupName(group.memberIDs) : prepared.name }
            group.grokSourceID = bundle.sourceId
            group.grokHistoryCount = historyCount
            if created {
                if policy != .legacyFileImport { group.isHidden = bundle.source?.hiddenFromSidebar ?? false }
                groups.append(group)
            }
            return GrokImportRow(name: group.name, profile: nil, historyCount: historyCount, mark: mapped,
                                 sourceShape: bundle.avatar?.shape, sourceColour: bundle.avatar?.colour, isGroup: true, created: created)
        case .bot(let bot, let kind):
            switch (policy, kind) {
            case (.legacyFileImport, _):
                applyIdentity(prepared, mapped: mapped, to: bot)
                bot.backend = .hermes; bot.hermesBaseURL = Self.grokHermesBaseURL
                bot.hermesProfile = Self.legacyProfile(bundle)
            case (.inApp, .linked):
                if refresh { applyIdentity(prepared, mapped: mapped, to: bot) }
            case (.inApp, .adopted):
                applyIdentity(prepared, mapped: mapped, to: bot)
            case (.inApp(let serverURL, _), .new):
                applyIdentity(prepared, mapped: mapped, to: bot)
                bot.backend = .hermes; bot.hermesBaseURL = serverURL
                bot.hermesProfile = grokBindingProfile(Self.grokCandidates(bundle), for: bot, serverSet: serverURL != nil)
                bot.isHidden = bundle.source?.hiddenFromSidebar ?? false
            }
            if kind != .linked || policy == .legacyFileImport { bot.archivedMembers = nil; bot.isDemo = false }
            bot.grokSourceID = bundle.sourceId
            bot.grokHistoryCount = historyCount
            mergeGrokStaged(prepared, into: bot)
            if kind == .new {
                bots.append(bot)
                // P49: a new bot from a Grok import orients itself once (a history-only one never chats, so it does not).
                if bot.hermesProfile != nil { queueOrientation(bot) }
            }
            return GrokImportRow(name: bot.name, profile: bot.hermesProfile, historyCount: historyCount, mark: mapped,
                                 sourceShape: bundle.avatar?.shape, sourceColour: bundle.avatar?.colour,
                                 isGroup: false, created: kind == .new)
        }
    }

    /// `--import-grok`'s rule since P6: `bundle.profile`, else `grok-<slug>`, if valid.
    private static func legacyProfile(_ bundle: GrokBotBundle) -> String? {
        [bundle.profile, bundle.slug.map { "grok-\($0)" }].compactMap { $0 }.first(where: HermesKeyPaste.isValidProfileName)
    }

    private func applyIdentity(_ prepared: PreparedGrokBundle, mapped: AvatarMark, to bot: Bot) {
        bot.name = prepared.name.isEmpty ? "Grok bot" : prepared.name
        bot.title = prepared.title.isEmpty ? "Imported from Grok Bot" : prepared.title
        bot.botDescription = prepared.description
        if !prepared.instructions.isEmpty { bot.persona = prepared.instructions }
        bot.avatarMark = mapped; bot.avatarMarkMigrated = false
    }
}
