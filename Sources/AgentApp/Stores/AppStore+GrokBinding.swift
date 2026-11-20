import Foundation

/// Where one bundle lands: a group, or a bot that was imported before (`linked`) or is new.
enum GrokImportTarget {
    enum Kind { case linked, new }
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
    func grokTarget(for prepared: PreparedGrokBundle) -> GrokImportTarget {
        let bundle = prepared.bundle
        if bundle.isGroup ?? false {
            if let existing = groups.first(where: { $0.grokSourceID == bundle.sourceId }) { return .group(existing, created: false) }
            return .group(GroupChat(name: "", memberIDs: resolveMembers(prepared.members)), created: true)
        }
        if let linked = bots.first(where: { $0.grokSourceID == bundle.sourceId }) { return .bot(linked, .linked) }
        return .bot(Bot(name: "", backend: .herdr), .new)
    }

    /// Applies a bundle whose history is already merged (`historyCount`) to its target and returns the report row.
    /// A new bot is a Herdr bot on the first server, with the name, avatar and instructions it had in Grok Bot; its
    /// imported chats are a read-only archive beside it. A bot imported before gets history only, unless the import
    /// refreshes identities.
    func apply(_ prepared: PreparedGrokBundle, to target: GrokImportTarget, historyCount: Int, policy: GrokImportPolicy) -> GrokImportRow {
        let bundle = prepared.bundle
        let mapped = GrokAvatarMap.map(shape: bundle.avatar?.shape, colour: bundle.avatar?.colour, sourceID: bundle.sourceId)
        let refresh: Bool
        if case .inApp(let refreshIdentity) = policy { refresh = refreshIdentity } else { refresh = true }
        switch target {
        case .group(let group, let created):
            if created || refresh { group.name = prepared.name.isEmpty ? defaultGroupName(group.memberIDs) : prepared.name }
            group.grokSourceID = bundle.sourceId
            group.grokHistoryCount = historyCount
            if created {
                if policy != .fileImport { group.isHidden = bundle.source?.hiddenFromSidebar ?? false }
                groups.append(group)
            }
            return GrokImportRow(name: group.name, historyCount: historyCount, mark: mapped,
                                 sourceShape: bundle.avatar?.shape, sourceColour: bundle.avatar?.colour, isGroup: true, created: created)
        case .bot(let bot, let kind):
            if kind == .new || refresh { applyIdentity(prepared, mapped: mapped, to: bot) }
            if kind == .new {
                bot.backend = .herdr
                if policy != .fileImport { bot.isHidden = bundle.source?.hiddenFromSidebar ?? false }
            }
            bot.archivedMembers = nil; bot.isDemo = false
            bot.grokSourceID = bundle.sourceId
            bot.grokHistoryCount = historyCount
            if kind == .new {
                bots.append(bot)
                setHerdrServer(herdrServers[0].id, for: bot)
                setHerdrModel(HerdrModelChoice.recommended, for: bot)
            }
            return GrokImportRow(name: bot.name, historyCount: historyCount, mark: mapped,
                                 sourceShape: bundle.avatar?.shape, sourceColour: bundle.avatar?.colour,
                                 isGroup: false, created: kind == .new)
        }
    }

    static func importedGrokName(_ name: String) -> String {
        let clean = PreparedGrokBundle.cleanIdentity(name)
        return clean.isEmpty ? "Grok bot" : clean
    }

    private func applyIdentity(_ prepared: PreparedGrokBundle, mapped: AvatarMark, to bot: Bot) {
        bot.name = Self.importedGrokName(prepared.name)
        bot.title = prepared.title.isEmpty ? "Imported from Grok Bot" : prepared.title
        bot.botDescription = prepared.description
        if !prepared.instructions.isEmpty { bot.persona = prepared.instructions }
        bot.avatarMark = mapped; bot.avatarMarkMigrated = false
    }
}
