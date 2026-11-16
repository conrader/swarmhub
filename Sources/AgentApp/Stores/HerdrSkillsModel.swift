import Foundation

/// One Herdr server's Skills section, shared by Settings and a bot's Details: the library as last read, the switches
/// the person moved, and whether the agent programs have what the library says. On and off mean what they say: a
/// switch changes the library and then runs a sync, so the agent programs get the change. When the sync fails the
/// section says that the switch changed and the agent programs did not, and offers Retry. Switches moved in a row go
/// to the server one after another, and one sync follows the last.
@MainActor final class HerdrSkillsModel: ObservableObject {
    enum Phase: Equatable { case idle, reading, ready, unavailable(String) }
    /// The agent programs are behind the library: a sync is waiting (a dry run found it), or one failed, with the line that says so.
    enum Behind: Equatable { case waiting, failed(String) }
    /// "Share with …": closed until the person opens it, because the server runs a discovery to answer.
    enum Sharing: Equatable { case closed, asking, offered([String]), failed(String) }

    @Published private(set) var phase: Phase
    @Published private(set) var library: HerdrSkillLibrary?
    @Published var query: String
    /// Switches the person moved that the server has not answered yet, by skill id.
    @Published private(set) var wanted: [String: Bool] = [:]
    @Published private(set) var syncing = false
    /// The short result of the last switch, sync or refusal.
    @Published private(set) var note: String
    @Published private(set) var behind: Behind?
    @Published private(set) var sharing: Sharing
    /// The agent program whose sharing waits for the person's yes.
    @Published var confirming: String?
    @Published private(set) var adding = false

    private let client: @MainActor () throws -> HerdrClient
    private var chain: Task<Void, Never>?
    private var queued = 0
    /// What changed in the library since the last sync that went through, for the line a failed sync shows.
    private var unsynced: [String] = []

    init(client: @escaping @MainActor () throws -> HerdrClient) {
        self.client = client; phase = .idle; query = ""; note = ""; sharing = .closed
    }

    /// A state to show without a server (renders and tests).
    init(showing library: HerdrSkillLibrary?, phase: Phase = .ready, query: String = "", note: String = "", behind: Behind? = nil, sharing: Sharing = .closed, confirming: String? = nil) {
        client = { throw HerdrClient.Failure.invalidURL }
        self.library = library; self.phase = phase; self.query = query; self.note = note; self.behind = behind; self.sharing = sharing; self.confirming = confirming
    }

    func isOn(_ skill: HerdrSkillLibrary.Skill) -> Bool { wanted[skill.id] ?? skill.enabled }
    func isChanging(_ skill: HerdrSkillLibrary.Skill) -> Bool { wanted[skill.id] != nil }
    var isBusy: Bool { queued > 0 || syncing || adding }

    /// Reads the library, then asks with a dry run (which changes nothing) whether a sync is waiting.
    func load() async {
        if library == nil { phase = .reading }
        do {
            let client = try client()
            let read = try await client.skillLibrary()
            library = read; phase = .ready
            guard read.installed, !read.targets.isEmpty, queued == 0, !syncing, let dry = try? await client.syncSkills(dryRun: true) else { return }
            if !dry.isPending { behind = nil } else if behind == nil { behind = .waiting }
        } catch { if library == nil { phase = .unavailable(HerdrSkillsCopy.reason(error)) } else { note = HerdrSkillsCopy.reason(error) } }
    }

    /// The switch: shown at once, sent after the switches before it, and followed by a sync once none is waiting.
    func set(_ skill: HerdrSkillLibrary.Skill, on: Bool) {
        guard isOn(skill) != on else { return }
        wanted[skill.id] = on; note = ""; queued += 1
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await self?.change(skill, on: on)
        }
    }

    /// Waits for the switches and the sync that are on their way (tests).
    func settled() async { await chain?.value }

    private func change(_ skill: HerdrSkillLibrary.Skill, on: Bool) async {
        do {
            let answer = try await client().setSkill(skill.name, enabled: on)
            library = answer
            // An empty `changed`: the skill already was as asked and nothing ran, so there is nothing to bring over.
            if let changed = answer.changed, !changed.isEmpty { unsynced.append(HerdrSkillsCopy.changedInLibrary(changed, on: on)) }
            note = HerdrSkillsCopy.switched(skill.name, on: on)
        } catch { note = HerdrSkillsCopy.reason(error) }
        wanted[skill.id] = nil
        queued -= 1
        if queued == 0, !unsynced.isEmpty { await sync() }
    }

    /// Brings the agent programs up to date with the library; also Retry after a sync that failed.
    func sync() async {
        guard !syncing else { return }
        syncing = true; defer { syncing = false }
        let said = note
        do {
            let done = try await client().syncSkills()
            if let targets = done.targets { library?.targets = targets }
            unsynced = []; behind = nil
            note = ([said, HerdrSkillsCopy.synced(done.targetsLine), done.problem ?? ""].filter { !$0.isEmpty }).joined(separator: " ")
        } catch {
            let what = unsynced.isEmpty ? "The library changed" : HerdrSkillLibrary.list(unsynced)
            behind = .failed(HerdrSkillsCopy.notSynced(what, reason: HerdrSkillsCopy.reason(error)))
        }
    }

    /// Asks the server which agent programs the library could also be shared with. Only when the person opens the control.
    func openSharing() async {
        sharing = .asking; confirming = nil
        do {
            let offer = try await client().skillTargetsAddable()
            if let problem = offer.problem, !problem.isEmpty { sharing = .failed(problem) } else { sharing = .offered(offer.agents ?? []) }
        } catch { sharing = .failed(HerdrSkillsCopy.reason(error)) }
    }

    func closeSharing() { sharing = .closed; confirming = nil }

    /// After the person's yes: the agent program becomes a Target, and a sync links the skills into its folder.
    func share(with agent: String) async {
        guard !adding, confirming == agent else { return }
        adding = true; defer { adding = false }
        confirming = nil; note = ""
        do {
            let answer = try await client().addSkillTarget(agent)
            if let targets = answer.targets { library?.targets = targets }
            sharing = .closed; unsynced.append(HerdrSkillsCopy.sharedInLibrary(agent)); note = HerdrSkillsCopy.shared(agent)
        } catch { note = HerdrSkillsCopy.reason(error); return }
        await sync()
    }
}

extension AppStore {
    /// The Skills section of one server; Settings and every bot's Details on that server show the same one.
    func herdrSkillsModel(for server: HerdrServer) -> HerdrSkillsModel {
        if let model = herdrSkillModels[server.id] { return model }
        let id = server.id
        let model = HerdrSkillsModel { [weak self] in
            guard let self else { throw HerdrClient.Failure.invalidURL }
            return try self.herdrClient(for: self.herdrServer(id: id) ?? server)
        }
        herdrSkillModels[id] = model
        return model
    }
}
