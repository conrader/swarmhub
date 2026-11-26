import Foundation

/// Portable group definitions. Chat history, sessions, access grants and connection settings stay in the workspace.
struct TeamPack: Codable {
    struct Member: Codable {
        let name: String
        let title: String
        let description: String
        let instructions: String
        let avatar: BotAvatarName
        let mark: AvatarMark?
        let template: String?
        let model: String?
        var workflow: TeamWorkflow<Int>? = nil
    }

    let format: String
    let name: String
    let members: [Member]

    private static let formatID = "swarmhub-team-pack/v1"
    private static let maxBytes = 1024 * 1024

    @MainActor init(group: GroupChat, store: AppStore) throws {
        format = group.workflows.values.contains(where: { !$0.isEmpty }) ? "swarmhub-team-pack/v2" : Self.formatID
        name = group.name
        let bots = store.members(of: group)
        guard Set(group.memberIDs).count == group.memberIDs.count, bots.count == group.memberIDs.count, bots.allSatisfy({ !$0.isReadOnlyArchive }) else {
            throw BackendError.unavailable("This group contains a missing or archived bot.")
        }
        let positions = Dictionary(uniqueKeysWithValues: bots.enumerated().map { ($0.element.id, $0.offset) })
        members = try bots.map { bot in
            let workflow = try group.workflows[bot.id]?.remapping { id in
                guard let index = positions[id] else { throw BackendError.unavailable("A handoff recipient has left the group.") }
                return index
            }
            return Member(name: bot.name, title: bot.title, description: bot.botDescription, instructions: bot.outboundPersona,
                   avatar: bot.avatarName, mark: bot.avatarMark, template: store.herdrTemplate(for: bot),
                   model: store.herdrModel(for: bot), workflow: workflow?.isEmpty == false ? workflow : nil)
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        _ = try Self.decode(data)
        return data
    }

    static func read(_ url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: maxBytes + 1) ?? Data())
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw BackendError.unavailable("Team Packs can be up to 1 MB.") }
        guard let pack = try? JSONDecoder().decode(Self.self, from: data), [formatID, "swarmhub-team-pack/v2"].contains(pack.format) else {
            throw BackendError.unavailable("Choose a SwarmHub Team Pack JSON file.")
        }
        guard !pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pack.members.count >= 2, pack.members.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BackendError.unavailable("A Team Pack needs a group name and at least two named bots.")
        }
        for (index, member) in pack.members.enumerated() {
            try member.workflow?.validate(owner: index, members: Array(pack.members.indices))
        }
        // Inspect decoded strings, so JSON escapes cannot hide a credential inside an instruction.
        var fields = [pack.name]
        for member in pack.members {
            fields += [member.name, member.title, member.description, member.instructions]
            fields += [member.template, member.model, member.mark?.shape, member.mark?.colour].compactMap { $0 }
            if let workflow = member.workflow {
                fields += workflow.skills.flatMap { [$0.name, $0.instructions] }
                fields += workflow.handoffs.map(\.condition)
            }
        }
        guard !fields.contains(where: { !SecretFilter.redact($0).isEmpty }) else {
            throw BackendError.unavailable("A Team Pack field contains a possible credential. Remove it before sharing.")
        }
        return pack
    }
}

extension AppStore {
    func importTeamPack(_ pack: TeamPack, on server: HerdrServer) throws {
        guard persistenceEnabled, storeRestoreOffer == nil, herdrServers.contains(server) else {
            throw BackendError.unavailable("The destination workspace is unavailable.")
        }
        let imported = pack.members.map { member in
            let bot = Bot(name: member.name, title: member.title, description: member.description, persona: member.instructions,
                          backend: .herdr, avatarName: member.avatar)
            bot.avatarMark = member.mark
            return bot
        }
        let group = GroupChat(name: pack.name, memberIDs: imported.map(\.id))
        for (bot, member) in zip(imported, pack.members) {
            group.workflows[bot.id] = try member.workflow?.remapping { index in
                guard imported.indices.contains(index) else { throw BackendError.unavailable("Unknown handoff recipient.") }
                return imported[index].id
            }
        }
        let previousBots = bots, previousGroups = groups
        for (bot, member) in zip(imported, pack.members) {
            setHerdrServer(server.id, for: bot)
            setHerdrTemplate(member.template ?? "", for: bot)
            setHerdrModel(member.model ?? "", for: bot)
            clearModelSwitch(bot.id)
        }
        bots.insert(contentsOf: imported, at: 0)
        groups.append(group)
        do { try writeStore() }
        catch {
            bots = previousBots
            groups = previousGroups
            for bot in imported {
                defaults.removeObject(forKey: HerdrServer.botKey(bot.id))
                defaults.removeObject(forKey: HerdrBackend.botTemplateKey(bot.id))
                defaults.removeObject(forKey: HerdrBackend.botModelKey(bot.id))
            }
            throw error
        }
        open(group)
    }
}
