import Foundation

/// One Herdr server's project servers and projects, shared by Settings, the setup wizard and every bot's settings on
/// that server: the lists as last read, the steps of adding a server (the Herdr server's key, the address, the
/// fingerprint to check, the result) and the project being written. Every refusal is shown in the workspace's own
/// sentence. Nothing here trusts a host key by itself: `trust` runs only when the person pressed its button.
@MainActor final class HerdrProjectsModel: ObservableObject {
    enum Phase: Equatable { case idle, reading, ready, unavailable(String) }
    /// Adding a server: its fields, the request on its way, the host's fingerprints waiting for the person's yes,
    /// what was added (the workspace's sentence, with the server's warnings), or why not.
    enum Adding: Equatable {
        case fields, working
        case trust(HerdrRefusal)
        case done(message: String, warnings: [String])
        case failed(String)
    }
    /// A project being written; `id` nil for a new one.
    struct Draft: Equatable {
        var id: Int?
        var name = "", machine = "", folder = "", note = ""
        var isComplete: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !machine.isEmpty && folder.trimmingCharacters(in: .whitespaces).hasPrefix("/") }
    }

    @Published private(set) var phase: Phase
    @Published private(set) var listing: HerdrMachines
    @Published private(set) var keys: HerdrSSHKeys?
    @Published private(set) var projects: [HerdrProject]
    @Published var adding: Adding
    /// The fields of adding a server.
    @Published var target = ""
    @Published var name = ""
    @Published var draft: Draft?
    /// The project request on its way, and what the last one said when it was refused.
    @Published private(set) var savingProject = false
    @Published private(set) var projectProblem = ""
    /// The server whose button is working (reconnect or remove), and the last sentence about one, by server name.
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var said: [String: String] = [:]
    @Published private(set) var makingKey = false

    private let client: @MainActor () throws -> HerdrClient

    init(client: @escaping @MainActor () throws -> HerdrClient) {
        self.client = client; phase = .idle; listing = HerdrMachines(); projects = []; adding = .fields
    }

    /// A state to show without a server (renders and tests).
    init(showing listing: HerdrMachines, keys: HerdrSSHKeys? = nil, projects: [HerdrProject] = [], phase: Phase = .ready, adding: Adding = .fields, target: String = "", name: String = "", draft: Draft? = nil) {
        client = { throw HerdrClient.Failure.invalidURL }
        self.listing = listing; self.keys = keys; self.projects = projects; self.phase = phase; self.adding = adding; self.target = target; self.name = name; self.draft = draft
    }

    var machines: [HerdrMachine] { listing.machines }
    /// The line to paste on the project server: the first key the Herdr server would use.
    var publicKey: String? { keys?.keys.first?.publicKey }
    var canAdd: Bool { listing.canAdd != false }
    var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Reads the servers, the Herdr server's key and the projects. A workspace without these routes says it is older.
    func load() async {
        if phase != .ready { phase = .reading }
        do {
            let client = try client()
            listing = try await client.machines()
            keys = try? await client.sshKeys()
            projects = (try? await client.projects()) ?? projects
            phase = .ready
        } catch { if phase != .ready { phase = .unavailable(HerdrProjectsCopy.reason(error)) } }
    }

    /// Makes the Herdr server's key pair when it has none; the workspace never replaces one.
    func makeKey() async {
        guard !makingKey else { return }
        makingKey = true; defer { makingKey = false }
        do { keys = try await client().createSSHKey() } catch { keys = HerdrSSHKeys(keys: keys?.keys ?? [], canCreate: keys?.canCreate, whereToPaste: keys?.whereToPaste, problem: HerdrProjectsCopy.reason(error)) }
    }

    /// "Add server": asks the workspace. A host the Herdr server has not seen comes back with its fingerprints, and
    /// nothing is trusted until `trust`.
    func add() async { await send(accepting: nil) }

    /// "Trust this server": adds it again with the fingerprint the person was shown.
    func trust(_ key: HerdrRefusal.HostKey) async {
        guard case .trust(let question) = adding, question.hostKeys.contains(key) else { return }
        await send(accepting: key.fingerprint)
    }

    private func send(accepting fingerprint: String?) async {
        let target = trimmedTarget
        guard !target.isEmpty, adding != .working else { return }
        adding = .working
        guard let client = try? client() else { adding = .failed(HerdrBackend.missingToken); return }
        switch await client.addMachine(target: target, name: name.trimmingCharacters(in: .whitespacesAndNewlines), accepting: fingerprint) {
        case .added(let added):
            adding = .done(message: added.message ?? "Added \(added.machine.name).", warnings: added.machine.warnings)
            self.target = ""; name = ""
            await load()
        case .unknownHost(let question): adding = .trust(question)
        case .refused(let why): adding = .failed(why)
        }
    }

    /// Back to the fields, keeping what was typed (after a refusal) or empty (after a success).
    func addAgain() { adding = .fields }

    func reconnect(_ machine: HerdrMachine) async {
        busy.insert(machine.name); defer { busy.remove(machine.name) }
        do {
            let now = try await client().connectMachine(machine.name)
            if let index = listing.machines.firstIndex(where: { $0.name == machine.name }) { listing.machines[index] = now }
            said[machine.name] = now.reachable ? "\(now.name) is connected." : now.warnings.first ?? "\(now.name): \(now.stateLine)."
        } catch { said[machine.name] = HerdrProjectsCopy.reason(error) }
    }

    /// Makes Herdr forget a server. One that still has projects is refused, in the workspace's sentence.
    func remove(_ machine: HerdrMachine) async {
        busy.insert(machine.name); defer { busy.remove(machine.name) }
        do { listing = try await client().removeMachine(machine.name); said[machine.name] = nil }
        catch { said[machine.name] = HerdrProjectsCopy.reason(error) }
    }

    func newProject(on machine: String? = nil) { projectProblem = ""; draft = Draft(machine: machine ?? machines.first?.name ?? "") }
    func edit(_ project: HerdrProject) { projectProblem = ""; draft = Draft(id: project.id, name: project.name, machine: project.machine, folder: project.folder, note: project.note) }

    /// Saves the project being written. Returns it when the workspace took it.
    @discardableResult func saveProject() async -> HerdrProject? {
        guard let draft, draft.isComplete, !savingProject else { return nil }
        savingProject = true; defer { savingProject = false }
        projectProblem = ""
        let name = draft.name.trimmingCharacters(in: .whitespaces), folder = draft.folder.trimmingCharacters(in: .whitespaces), note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let client = try client()
            let saved: HerdrProject
            if let id = draft.id { saved = try await client.changeProject(id, name: name, machine: draft.machine, folder: folder, note: note) }
            else { saved = try await client.addProject(name: name, machine: draft.machine, folder: folder, note: note) }
            if let index = projects.firstIndex(where: { $0.id == saved.id }) { projects[index] = saved } else { projects.append(saved) }
            self.draft = nil
            if let fresh = try? await client.machines() { listing = fresh }
            return saved
        } catch { projectProblem = HerdrProjectsCopy.reason(error); return nil }
    }

    func removeProject(_ project: HerdrProject) async {
        do {
            let client = try client()
            projects = try await client.removeProject(project.id)
            if draft?.id == project.id { draft = nil }
            if let fresh = try? await client.machines() { listing = fresh }
        } catch { projectProblem = HerdrProjectsCopy.reason(error) }
    }
}

extension AppStore {
    /// The project servers of one Herdr server; Settings and every bot on that server show the same one.
    func herdrProjectsModel(for server: HerdrServer) -> HerdrProjectsModel {
        if let model = herdrProjectModels[server.id] { return model }
        let id = server.id
        let model = HerdrProjectsModel { [weak self] in
            guard let self else { throw HerdrClient.Failure.invalidURL }
            return try self.herdrClient(for: self.herdrServer(id: id) ?? server)
        }
        herdrProjectModels[id] = model
        return model
    }

    // MARK: A bot's projects

    static func herdrProjectsKey(_ botID: UUID) -> String { "herdrProjects.\(botID.uuidString.lowercased())" }
    static func herdrProjectsChangedKey(_ botID: UUID) -> String { "herdrProjectsChanged.\(botID.uuidString.lowercased())" }

    /// The projects on other servers this bot may use, in the order they were chosen. None unless the person chose some.
    func herdrProjects(for bot: Bot) -> [HerdrBotProject] {
        guard let data = defaults.data(forKey: Self.herdrProjectsKey(bot.id)) else { return [] }
        return (try? JSONDecoder().decode([HerdrBotProject].self, from: data)) ?? []
    }

    /// The bot's list changed since its running agent was last given it.
    func herdrProjectsChanged(_ bot: Bot) -> Bool { defaults.bool(forKey: Self.herdrProjectsChangedKey(bot.id)) }

    /// Saves the bot's list. Its next agent starts with it; a running agent gets it with `applyHerdrProjects`, or
    /// failing that with the bot's next message.
    func setHerdrProjects(_ projects: [HerdrBotProject], for bot: Bot) {
        guard projects != herdrProjects(for: bot) else { return }
        if projects.isEmpty { defaults.removeObject(forKey: Self.herdrProjectsKey(bot.id)) }
        else if let data = try? JSONEncoder().encode(projects) { defaults.set(data, forKey: Self.herdrProjectsKey(bot.id)) }
        defaults.set(true, forKey: Self.herdrProjectsChangedKey(bot.id))
        objectWillChange.send()
    }

    /// Gives the bot's running agent the list as it is now. Returns what to say: that the running agent has it (it
    /// is told with the next message), that the next agent starts with it, or why the running agent still has the old one.
    @discardableResult func applyHerdrProjects(for bot: Bot) async -> String {
        guard herdrProjectsChanged(bot) else { return "" }
        // An agent that was started ahead of time and has not been written to starts again with this list, which
        // the server then tells it with its first message like any other.
        if launchWorkEnabled { await herdrChoiceChanged(for: bot) }
        guard herdrProjectsChanged(bot) else { return HerdrProjectsCopy.botChanged(running: true) }
        let wanted = herdrProjects(for: bot)
        do {
            let backend = try herdrBackend(for: bot)
            guard let agent = backend.client.liveAgent(named: backend.agentName, in: try await backend.client.workspace()) else {
                // Nothing runs: the launch carries the list.
                return HerdrProjectsCopy.botChanged(running: false)
            }
            try await backend.client.setAgentProjects(wanted.map(\.id), for: agent)
            // Only when the list did not change again meanwhile.
            if herdrProjects(for: bot) == wanted { defaults.removeObject(forKey: Self.herdrProjectsChangedKey(bot.id)) }
            return HerdrProjectsCopy.botChanged(running: true)
        } catch { return HerdrProjectsCopy.botNotApplied(HerdrProjectsCopy.reason(error)) }
    }

    /// The server's list was read: a bot's chosen projects take their names from it, and one that is gone leaves the list.
    func reconcileHerdrProjects(on server: HerdrServer, with listed: [HerdrProject]) {
        for bot in herdrBots(on: server) {
            let chosen = herdrProjects(for: bot)
            guard !chosen.isEmpty else { continue }
            let fresh = chosen.compactMap { kept in listed.first { $0.id == kept.id }.map(HerdrBotProject.init) }
            if fresh != chosen { setHerdrProjects(fresh, for: bot) }
        }
    }
}
