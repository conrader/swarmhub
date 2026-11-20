import Foundation

/// A tested host and the choices shown in the import review.
struct GrokDestination: Sendable, Equatable {
    let serverID: String
    let offer: HerdrOffer
    var testedHost: HerdrServer? = nil
    var template: String? = nil
    var templates: [String: String] = [:]
    var newBotIDs: [String: UUID] = [:]
    var descriptions: [String: String] = [:]

    func program(for source: String) -> HerdrProgram? {
        (templates[source] ?? template).flatMap(offer.program) ?? offer.programs.first
    }
}

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
    func grokTarget(for prepared: PreparedGrokBundle, destination: GrokDestination? = nil) -> GrokImportTarget {
        let bundle = prepared.bundle
        if bundle.isGroup ?? false {
            if let existing = groups.first(where: { $0.grokSourceID == bundle.sourceId }) { return .group(existing, created: false) }
            return .group(GroupChat(name: "", memberIDs: resolveMembers(prepared.members)), created: true)
        }
        if let linked = bots.first(where: { $0.grokSourceID == bundle.sourceId }) { return .bot(linked, .linked) }
        return .bot(Bot(id: destination?.newBotIDs[bundle.sourceId] ?? UUID(), name: "", backend: .herdr), .new)
    }

    /// Applies a bundle whose history is already merged (`historyCount`) to its target and returns the report row.
    /// A new bot is a Herdr bot on the first server, with the name, avatar and instructions it had in Grok Bot; its
    /// imported chats are a read-only archive beside it. A bot imported before gets history only, unless the import
    /// refreshes identities.
    func apply(_ prepared: PreparedGrokBundle, to target: GrokImportTarget, historyCount: Int, policy: GrokImportPolicy, destination: GrokDestination? = nil) -> GrokImportRow {
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
            if let description = destination?.descriptions[bundle.sourceId] {
                bot.botDescription = PreparedGrokBundle.cleanIdentity(description)
            }
            bot.archivedMembers = nil; bot.isDemo = false
            bot.grokSourceID = bundle.sourceId
            bot.grokHistoryCount = historyCount
            if kind == .new {
                let server = herdrServer(id: destination?.serverID) ?? herdrServers[0]
                let needsMain = destination != nil && herdrMainBot(on: server) == nil
                bots.append(bot)
                setHerdrServer(server.id, for: bot)
                if let program = destination?.program(for: bundle.sourceId) {
                    setHerdrTemplate(program.template, for: bot)
                }
                setHerdrModel(HerdrModelChoice.recommended, for: bot)
                if needsMain { bot.canManageBots = true }
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
        if !prepared.description.isEmpty { bot.botDescription = prepared.description }
        if !prepared.instructions.isEmpty { bot.persona = prepared.instructions }
        bot.avatarMark = mapped; bot.avatarMarkMigrated = false
    }
}
