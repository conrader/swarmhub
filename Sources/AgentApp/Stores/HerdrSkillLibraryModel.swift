import Foundation

/// One Herdr server's library as the app shows it (Overview, Library, and the previews, installs and repository
/// actions that open from them), for a workspace that serves the library routes (API level 2). Settings and every
/// bot's Details on that server share one; a project's own library has its own (`project`).
///
/// What the model keeps to:
/// - A change is followed by a sync, so on and off, installed and removed mean what they say for the bots. When the
///   sync fails the model says that the change happened and the bots do not have it, and Sync is the way to retry.
/// - Removing, pushing, syncing both ways, resolving a conflict, installing a skill the audit blocked and sharing
///   with another agent program happen only through `confirmed()`, after `ask` put the question on the screen.
/// - Every refusal shows the workspace's own sentence.
/// - A workspace older than level 2 is `older`: the app then shows the switch list (`HerdrSkillsModel`).
@MainActor final class HerdrLibraryModel: ObservableObject {
    enum Phase: Equatable { case idle, reading, ready, older, unavailable(String) }
    enum Area: String, CaseIterable, Identifiable {
        case overview = "Overview", library = "Library", servers = "Servers"
        var id: String { rawValue }
    }
    /// The one slow thing under way; switches are tracked on their own (`wanted`).
    enum Work: Equatable { case syncing, checking, updating, removing, looking, pulling, pushing, bothWays, resolving, sharing }
    struct Note: Equatable {
        var text: String
        var isProblem = false
    }
    /// A question that must be answered before something that cannot be taken back, or that leaves the server.
    enum Confirm: Equatable, Identifiable {
        case remove(HerdrLibraryItem)
        case push, bothWays, resolve
        case installAnyway([String])
        case share(String)
        var id: String {
            switch self {
            case .remove(let item): "remove:\(item.id)"
            case .push: "push"
            case .bothWays: "both"
            case .resolve: "resolve"
            case .installAnyway(let names): "anyway:\(names.joined(separator: ","))"
            case .share(let agent): "share:\(agent)"
            }
        }
    }
    /// One thing opened to read: what the list knows of it, and what the server said there is to read.
    struct Preview: Equatable {
        var item: HerdrLibraryItem
        var loaded: HerdrLibraryPreview? = nil
        var loading = false
        var problem: String? = nil
    }
    struct Diff: Equatable {
        var title: String
        var text: String? = nil
        var loading = false
        var problem: String? = nil
        /// The thing it is about, and whether it shows the edits made to it since it was installed instead of what a sync would change.
        var item: HerdrLibraryItem? = nil
        var edits = false
        /// Only a skill that was installed from somewhere has edits to show.
        var offersEdits: Bool { item.map { $0.known == .skills && !($0.origin ?? "local").isEmpty && $0.origin != "local" } ?? false }
    }
    /// Installing from a repository: the field, the download and audit on their way, what was found, the install on
    /// its way, or why the repository could not be looked into.
    enum Install: Equatable {
        case closed, asking, inspecting
        case found(HerdrInstallInspection)
        case installing(HerdrInstallInspection)
        case failed(String)
    }
    /// "Share with another AI": closed until the person opens it, because the server runs a discovery to answer.
    enum Sharing: Equatable { case closed, asking, offered([String]), failed(String) }

    /// A state to show without a server (renders and tests).
    struct Preset {
        var library: HerdrLibrary?
        var level = HerdrLibraryGate.level
        var phase = Phase.ready
        var area = Area.overview
        var kind: HerdrLibraryKind? = nil
        var query = ""
        var note: Note? = nil
        var behind: String? = nil
        var work: Work? = nil
        var confirm: Confirm? = nil
        var preview: Preview? = nil
        var diff: Diff? = nil
        var install = Install.closed
        var installSource = ""
        var installNote: Note? = nil
        var chosen: Set<String> = []
        var forced: Set<String> = []
        var source: HerdrLibrarySource? = nil
        var message = ""
        var conflict: HerdrSourceAnswer.Conflict? = nil
        var choices: [String: String] = [:]
        var sharing = Sharing.closed
        var scopes: [String: [HerdrLibraryScope.Choice]] = [:]
        var project: String? = nil
    }

    @Published private(set) var phase: Phase
    /// The workspace's API level, once it answered.
    @Published private(set) var level: Int?
    @Published private(set) var library: HerdrLibrary?
    @Published var area: Area
    /// The kind the Library area shows; nil for every kind.
    @Published var kind: HerdrLibraryKind?
    @Published var query: String
    /// Switches the person moved that the server has not answered yet, by id.
    @Published private(set) var wanted: [String: Bool] = [:]
    @Published private(set) var work: Work?
    /// The short result of the last action or refusal.
    @Published private(set) var note: Note?
    /// A change is in the library and a sync did not bring it to the bots, with the line that says so.
    @Published private(set) var behind: String?
    @Published var confirm: Confirm?
    @Published private(set) var preview: Preview?
    @Published private(set) var diff: Diff?
    @Published private(set) var install: Install
    @Published var installSource: String
    @Published private(set) var installNote: Note?
    /// The found skills that are ticked, by name; and the blocked ones the person said to install anyway.
    @Published private(set) var chosen: Set<String>
    @Published private(set) var forced: Set<String>
    @Published private(set) var source: HerdrLibrarySource?
    /// The note for a commit, typed before a push.
    @Published var message: String
    @Published private(set) var conflict: HerdrSourceAnswer.Conflict?
    /// `mine` or `theirs` for each file of the conflict the person has decided.
    @Published private(set) var choices: [String: String]
    @Published private(set) var sharing: Sharing
    /// The projects with a library of their own that a bot could look at instead, by bot.
    @Published private(set) var scopes: [String: [HerdrLibraryScope.Choice]]

    /// The folder of the project whose library this is; nil for the one all bots on the server share.
    let project: String?
    var now: () -> Date = Date.init
    private let client: @MainActor () throws -> HerdrClient
    private var chain: Task<Void, Never>?
    private var queued = 0
    /// What changed in the library since the last sync that went through, for the line a failed sync shows.
    private var unsynced: [String] = []
    private var host: String?

    init(project: String? = nil, client: @escaping @MainActor () throws -> HerdrClient) {
        self.client = client; self.project = project
        phase = .idle; area = .overview; query = ""; install = .closed; installSource = ""; chosen = []; forced = []; message = ""; choices = [:]; sharing = .closed; scopes = [:]
    }

    init(preset: Preset) {
        client = { throw HerdrClient.Failure.invalidURL }
        project = preset.project; library = preset.library; level = preset.level; phase = preset.phase; area = preset.area; kind = preset.kind; query = preset.query
        note = preset.note; behind = preset.behind; work = preset.work; confirm = preset.confirm; preview = preset.preview; diff = preset.diff
        install = preset.install; installSource = preset.installSource; installNote = preset.installNote; chosen = preset.chosen; forced = preset.forced
        source = preset.source; message = preset.message; conflict = preset.conflict; choices = preset.choices; sharing = preset.sharing; scopes = preset.scopes
    }

    /// A server from before the library: the app shows its switch list (renders and tests).
    static let olderServer = HerdrLibraryModel(preset: Preset(library: nil, level: 1, phase: .older))

    // MARK: Reading

    /// The workspace serves the library: the app shows it instead of the switch list.
    var isOpen: Bool { HerdrLibraryGate.open(api: level) }
    var isBusy: Bool { work != nil || queued > 0 }
    func isOn(_ item: HerdrLibraryItem) -> Bool { wanted[item.id] ?? item.enabled }
    func isChanging(_ item: HerdrLibraryItem) -> Bool { wanted[item.id] != nil }
    /// The thing as the newest answer has it.
    func current(_ item: HerdrLibraryItem) -> HerdrLibraryItem { library?.item(item.id) ?? item }

    /// Asks the workspace what level it serves, then reads the library. An older workspace is not asked for it.
    func load() async {
        if library == nil, phase != .older { phase = .reading }
        do {
            let client = try client()
            if !isOpen { level = try await client.workspace().bridge?.api ?? 0 }
            guard isOpen else { phase = .older; return }
            library = try await client.library(project: project); phase = .ready
        } catch {
            if library == nil { phase = .unavailable(Self.reason(error)) } else { note = Note(text: Self.reason(error), isProblem: true) }
        }
    }

    /// The library was opened: read it, and look for updates when that was not done in the last ten minutes. The
    /// repository's state is read along with it (the shared library only).
    func opened() async {
        await load()
        guard phase == .ready, let library, library.installed else { return }
        if project == nil { await loadSource() }
        if library.needsUpdateCheck(now: now()), work == nil { await check() }
    }

    /// Waits for the switches and the sync that are on their way (tests).
    func settled() async { await chain?.value }

    static func reason(_ error: Error) -> String { error.localizedDescription }

    private func fail(_ error: Error) { note = Note(text: Self.reason(error), isProblem: true) }

    /// Runs one slow thing at a time; a second request while one runs is dropped.
    private func working(_ kind: Work, _ body: @MainActor (HerdrClient) async throws -> Void) async {
        guard work == nil else { return }
        work = kind; defer { work = nil }
        do { try await body(try client()) } catch { fail(error) }
    }

    // MARK: Sync and switches

    /// Brings every Target up to date with the library; also the way to retry after a sync that failed.
    func sync() async {
        guard work == nil else { return }
        work = .syncing; defer { work = nil }
        let said = note.flatMap { $0.isProblem ? nil : $0.text } ?? ""
        do {
            let done = try await client().syncLibrary(project: project)
            if let after = done.library { library = after } else { library = try? await client().library(project: project) }
            unsynced = []; behind = nil
            note = Note(text: [said, HerdrLibraryCopy.synced, done.problem ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
        } catch {
            behind = HerdrLibraryCopy.notSynced(unsynced.isEmpty ? "The library changed." : unsynced.joined(separator: " "), reason: Self.reason(error))
        }
    }

    /// After a change to the library: one sync, when skillshare would run one. Otherwise the change stays waiting,
    /// and the overview says so.
    private func followUp(_ what: String) async {
        unsynced.append(what)
        guard queued == 0, library?.canSync == true else { return }
        await sync()
    }

    /// The switch: shown at once, sent after the switches before it, and followed by a sync once none is waiting.
    func set(_ item: HerdrLibraryItem, on: Bool) {
        guard item.canSwitch, isOn(item) != on else { return }
        wanted[item.id] = on; note = nil; queued += 1
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await self?.change(item, on: on)
        }
    }

    private func change(_ item: HerdrLibraryItem, on: Bool) async {
        var changed = false
        do {
            let answer = try await client().setLibraryItem(item.id, enabled: on, project: project)
            if let after = answer.library { library = after }
            // An empty `changed`: it already was as asked and nothing ran, so there is nothing to bring over.
            changed = !(answer.changed ?? [item.id]).isEmpty
            note = Note(text: HerdrLibraryCopy.switched(item, on: on))
            if preview?.item.id == item.id { preview?.item = current(item) }
        } catch { fail(error) }
        wanted[item.id] = nil
        queued -= 1
        if changed { unsynced.append(HerdrLibraryCopy.switched(item, on: on)) }
        if queued == 0, !unsynced.isEmpty, library?.canSync == true { await sync() }
    }

    // MARK: Reading one thing

    func open(_ item: HerdrLibraryItem) async {
        preview = Preview(item: item, loading: true)
        await read(item, file: nil)
    }

    /// Another of a skill's files.
    func show(file: String) async {
        guard let item = preview?.item, preview?.loaded?.file != file else { return }
        preview?.loading = true
        await read(item, file: file)
    }

    private func read(_ item: HerdrLibraryItem, file: String?) async {
        do {
            let loaded = try await client().libraryPreview(item.id, file: file, project: project)
            guard preview?.item.id == item.id else { return }
            preview?.loaded = loaded; preview?.problem = nil
        } catch { if preview?.item.id == item.id { preview?.problem = Self.reason(error) } }
        if preview?.item.id == item.id { preview?.loading = false }
    }

    func closePreview() { preview = nil }

    /// What a sync would change for this thing, or with `edits` what was edited in it since it was installed.
    func showDiff(_ item: HerdrLibraryItem, edits: Bool = false) async {
        diff = Diff(title: item.readable, loading: true, item: item, edits: edits)
        do {
            let answer = try await client().libraryDiff(item.id, edits: edits, project: project)
            diff = Diff(title: item.readable, text: answer.text ?? "", item: item, edits: edits)
        } catch { diff = Diff(title: item.readable, problem: Self.reason(error), item: item, edits: edits) }
    }

    func closeDiff() { diff = nil }

    // MARK: Updates

    /// Asks where every installed skill and agent came from whether there is a newer version. Slow.
    func check() async {
        await working(.checking) { client in
            let answer = try await client.checkLibrary(project: project)
            if let after = answer.library { library = after }
            if let problem = answer.problem, !problem.isEmpty { note = Note(text: problem, isProblem: true) }
            else { note = Note(text: HerdrLibraryCopy.checked(answer.updates ?? library?.updates.count ?? 0)) }
        }
    }

    /// Updates one thing, or with nil every one that has an update. What the audit refused is said as it is.
    func update(_ item: HerdrLibraryItem?) async {
        var done: String?
        await working(.updating) { client in
            let answer = try await client.updateLibrary(item?.id, project: project)
            if let after = answer.library { library = after }
            let blocked = answer.blocked ?? []
            note = Note(text: HerdrLibraryCopy.updated(answer.updated ?? 0, blocked: blocked), isProblem: !blocked.isEmpty)
            if let item, preview?.item.id == item.id { preview?.item = current(item) }
            if (answer.updated ?? 0) > 0 { done = HerdrLibraryCopy.updated(answer.updated ?? 0, blocked: []) }
        }
        if let done { await followUp(done) }
    }

    // MARK: Questions

    /// Puts a question on the screen. Nothing it asks about happens before `confirmed()`.
    func ask(_ question: Confirm) {
        if case .resolve = question, !conflictDecided { return }
        confirm = question
    }

    /// The person said yes to the question on the screen.
    func confirmed() async {
        guard let asked = confirm else { return }
        confirm = nil
        switch asked {
        case .remove(let item): await remove(item)
        case .push: await push()
        case .bothWays: await bothWays()
        case .resolve: await resolve()
        case .installAnyway(let names): forced.formUnion(names); chosen.formUnion(names)
        case .share(let agent): await share(with: agent)
        }
    }

    private func remove(_ item: HerdrLibraryItem) async {
        var done: String?
        await working(.removing) { client in
            let answer = try await client.uninstall(item.id, project: project)
            if let after = answer.library { library = after }
            note = Note(text: HerdrLibraryCopy.removed(answer.removed ?? [item.name]))
            if preview?.item.id == item.id { preview = nil }
            done = HerdrLibraryCopy.removed(answer.removed ?? [item.name])
        }
        if let done { await followUp(done) }
    }

    // MARK: Install

    func startInstall() { install = .asking; installSource = ""; installNote = nil; chosen = []; forced = [] }

    /// Has the server download the repository and audit its skills. Nothing is installed by this.
    func inspect() async {
        let source = installSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, install == .asking || isFailedInstall else { return }
        install = .inspecting; installNote = nil; chosen = []; forced = []
        do {
            let found = try await client().inspectInstall(source, project: project)
            // What passed is ticked. A blocked skill is ticked only by the person, through a confirmation.
            chosen = Set(found.passed.map(\.name)); install = .found(found)
        } catch { install = .failed(Self.reason(error)) }
    }
    private var isFailedInstall: Bool { if case .failed = install { true } else { false } }

    /// The inspection on the screen, also while its install runs.
    var inspection: HerdrInstallInspection? {
        switch install { case .found(let found), .installing(let found): found; default: nil }
    }
    /// Whether this found skill can be ticked: one the audit blocked only after the person said to install it anyway.
    func canChoose(_ skill: HerdrInstallInspection.Found) -> Bool { !(inspection?.isBlocked(skill) ?? false) || forced.contains(skill.name) }

    func toggle(_ skill: HerdrInstallInspection.Found) {
        guard case .found = install, canChoose(skill) else { return }
        if chosen.contains(skill.name) { chosen.remove(skill.name) } else { chosen.insert(skill.name) }
    }

    /// What Install would send now: the ticked skills in the repository's order, whether any replaces one the
    /// library has, and whether any is one the audit blocked (only ever one the person confirmed).
    var installPlan: (skills: [String], replace: Bool, force: Bool) {
        guard let inspection else { return ([], false, false) }
        let picked = inspection.skills.filter { chosen.contains($0.name) && canChoose($0) }
        return (picked.map(\.name), picked.contains(where: \.installed), picked.contains { inspection.isBlocked($0) })
    }

    func installChosen() async {
        guard case .found(let inspection) = install else { return }
        let plan = installPlan
        guard !plan.skills.isEmpty else { return }
        install = .installing(inspection); installNote = nil
        do {
            let answer = try await client().install(ticket: inspection.ticket, skills: plan.skills, replace: plan.replace, force: plan.force, project: project)
            if let after = answer.library { library = after }
            let said = HerdrLibraryCopy.installed(answer.installed ?? plan.skills, pinned: answer.pinned ?? false)
            install = .closed; note = Note(text: said)
            await followUp(said)
        } catch {
            install = .found(inspection); installNote = Note(text: Self.reason(error), isProblem: true)
        }
    }

    /// Closes the install; a download that waits on the server is removed there.
    func cancelInstall() async {
        let ticket = inspection?.ticket
        install = .closed; installNote = nil; chosen = []; forced = []
        if let ticket, !ticket.isEmpty { try? await client().cancelInstall(ticket: ticket, project: project) }
    }

    /// The found skills a bot would be asked about: the ones the audit blocked or found something in, else all.
    var reviewable: [HerdrInstallInspection.Found] {
        guard let inspection else { return [] }
        let flagged = inspection.skills.filter { inspection.isBlocked($0) || !$0.findings.isEmpty }
        return flagged.isEmpty ? inspection.skills : flagged
    }
    /// The message for the bot the person picks, and what to say once it was handed over (or could not be).
    var reviewRequest: String? { inspection.map { HerdrLibraryCopy.reviewRequest($0, skills: reviewable) } }
    func reviewAsked(of bot: String, sent: Bool) {
        installNote = Note(text: sent ? HerdrLibraryCopy.reviewSent(bot) : HerdrLibraryCopy.reviewBusy(bot), isProblem: !sent)
    }

    // MARK: The library's repository

    func loadSource(fetch: Bool = false) async {
        guard project == nil, isOpen else { return }
        // A server that cannot say leaves the card as it was; the repository is a side matter of the overview.
        if let read = try? await client().librarySource(fetch: fetch) { source = read }
    }

    /// `sent`: the answer is to a push, so the note that went with it is used up.
    private func take(_ answer: HerdrSourceAnswer, done: String, sent: Bool = true) {
        if let after = answer.source { source = after }
        if let after = answer.library { library = after }
        if let met = answer.conflict, !met.files.isEmpty {
            let again = conflict != nil
            conflict = met; choices = [:]
            note = again ? Note(text: HerdrLibraryCopy.conflictAgain, isProblem: true) : nil
        } else {
            conflict = nil; choices = [:]
            if sent { message = "" }
            note = Note(text: done)
        }
    }

    /// Asks the remote what is new, and reads the repository's state again.
    func lookAtSource() async {
        await working(.looking) { client in source = try await client.librarySource(fetch: true) }
    }

    /// Brings the repository's changes to the server and syncs the Targets.
    func pull() async {
        await working(.pulling) { client in take(try await client.pullSource(), done: HerdrLibraryCopy.pulled, sent: false) }
    }
    private func push() async {
        await working(.pushing) { client in take(try await client.pushSource(message: message), done: HerdrLibraryCopy.pushed) }
    }
    private func bothWays() async {
        await working(.bothWays) { client in take(try await client.syncSource(message: message), done: HerdrLibraryCopy.bothDone) }
    }

    func choose(_ path: String, _ side: String) {
        guard conflict?.files.contains(where: { $0.path == path }) == true, side == "mine" || side == "theirs" else { return }
        choices[path] = side
    }
    /// Every file of the conflict has a choice.
    var conflictDecided: Bool { conflict.map { met in !met.files.isEmpty && met.files.allSatisfy { choices[$0.path] != nil } } ?? false }
    func closeConflict() { conflict = nil; choices = [:] }

    private func resolve() async {
        guard let met = conflict, conflictDecided else { return }
        let chosen = choices
        await working(.resolving) { client in take(try await client.resolveSource(choices: chosen, push: met.push ?? false), done: HerdrLibraryCopy.resolved) }
    }

    // MARK: Sharing with another agent program

    /// Asks the server which agent programs the library could also be shared with. Only when the person opens it.
    func openSharing() async {
        sharing = .asking
        do {
            let offer = try await client().skillTargetsAddable()
            if let problem = offer.problem, !problem.isEmpty { sharing = .failed(problem) } else { sharing = .offered(offer.agents ?? []) }
        } catch { sharing = .failed(Self.reason(error)) }
    }
    func closeSharing() { sharing = .closed }

    private func share(with agent: String) async {
        var done: String?
        await working(.sharing) { client in
            _ = try await client.addSkillTarget(agent)
            sharing = .closed; note = Note(text: HerdrLibraryCopy.shared(agent))
            library = (try? await client.library(project: project)) ?? library
            done = HerdrLibraryCopy.shared(agent)
        }
        if let done { await followUp(done) }
    }

    // MARK: A project's own library

    /// Finds which of a bot's projects hold a library of their own: only projects on the server itself are asked
    /// about, and nothing is said about the others. Quiet when the server cannot say.
    func findScopes(for bot: String, among candidates: [HerdrLibraryScope.Candidate]) async {
        guard isOpen, project == nil, !candidates.isEmpty else { scopes[bot] = []; return }
        do {
            let client = try client()
            if host == nil { host = try await client.skillshareMachine().host ?? "" }
            let local = HerdrLibraryScope.local(candidates, host: host)
            guard !local.isEmpty else { scopes[bot] = []; return }
            let holding = try await client.skillshareProjects(folders: local.map(\.folder)).projects.map(\.folder)
            scopes[bot] = local.filter { holding.contains($0.folder) }
        } catch { scopes[bot] = [] }
    }
}

/// skillshare on every server the app knows, for the Servers area: each server has its own workspace, so each is
/// asked on its own. skillshare's newest release is looked for when asked, and by itself at most once an hour.
@MainActor final class HerdrLibraryServersModel: ObservableObject {
    struct State: Equatable {
        enum Phase: Equatable { case reading, ready, older, unreachable(String) }
        var phase = Phase.reading
        var machine: HerdrLibraryMachine? = nil
        /// Looking for a newer skillshare, or installing it.
        var working = false
        var note: String? = nil
        var noteIsProblem = false
    }

    @Published private(set) var states: [String: State]
    /// The server whose skillshare update waits for the person's yes.
    @Published var confirming: String?
    var now: () -> Date = Date.init
    private var releaseChecked: [String: Date] = [:]
    private let client: @MainActor (HerdrServer) throws -> HerdrClient

    init(client: @escaping @MainActor (HerdrServer) throws -> HerdrClient) { self.client = client; states = [:] }
    /// States to show as they are (renders and tests).
    init(states: [String: State], confirming: String? = nil) {
        client = { _ in throw HerdrClient.Failure.invalidURL }
        self.states = states; self.confirming = confirming
    }

    func state(for server: HerdrServer) -> State? { states[server.id] }

    /// Asks every server at once.
    func load(_ servers: [HerdrServer]) async {
        states = states.filter { id, _ in servers.contains { $0.id == id } }
        await withTaskGroup(of: Void.self) { group in
            for server in servers { group.addTask { await self.read(server, checkRelease: nil) } }
        }
    }

    /// Looks for skillshare's newest release now, because the person asked.
    func check(_ server: HerdrServer) async { await read(server, checkRelease: true) }

    private func read(_ server: HerdrServer, checkRelease: Bool?) async {
        var state = states[server.id] ?? State()
        guard !state.working else { return }
        if state.machine == nil { state.phase = .reading }
        let look = checkRelease ?? HerdrLibraryCopy.shouldCheckRelease(last: releaseChecked[server.id], now: now())
        state.working = checkRelease == true; state.note = nil; states[server.id] = state
        do {
            let client = try client(server)
            let level = try await client.workspace().bridge?.api
            guard HerdrLibraryGate.open(api: level) else { states[server.id] = State(phase: .older); return }
            var machine = try await client.skillshareMachine(check: look)
            if look { releaseChecked[server.id] = now() }
            // An answer without the release keeps what the last look found.
            else if let known = states[server.id]?.machine, known.version == machine.version { machine.latest = known.latest; machine.updateAvailable = known.updateAvailable }
            states[server.id] = State(phase: .ready, machine: machine)
        } catch {
            states[server.id] = State(phase: .unreachable(HerdrSetupProblem.of(error).line(for: server)))
        }
    }

    /// The person said yes: replaces the skillshare program on that server with the newest release.
    func upgrade(_ server: HerdrServer) async {
        guard confirming == server.id, var state = states[server.id], !state.working else { return }
        confirming = nil
        state.working = true; state.note = nil; states[server.id] = state
        do {
            let done = try await client(server).upgradeSkillshare()
            states[server.id]?.working = false
            await read(server, checkRelease: false)
            states[server.id]?.note = HerdrLibraryCopy.upgraded(done.version)
            if let version = done.version { states[server.id]?.machine?.version = version; states[server.id]?.machine?.updateAvailable = false }
        } catch {
            state.working = false; state.note = HerdrLibraryModel.reason(error); state.noteIsProblem = true; states[server.id] = state
        }
    }
}

extension AppStore {
    /// One server's library; Settings and every bot's Details on that server show the same one. `project`: the
    /// folder of a project on that server with a library of its own.
    func herdrLibraryModel(for server: HerdrServer, project: String? = nil) -> HerdrLibraryModel {
        let key = project.map { "\(server.id)\n\($0)" } ?? server.id
        if let model = herdrLibraryModels[key] { return model }
        let id = server.id
        let model = HerdrLibraryModel(project: project) { [weak self] in
            guard let self else { throw HerdrClient.Failure.invalidURL }
            return try self.herdrClient(for: self.herdrServer(id: id) ?? server)
        }
        herdrLibraryModels[key] = model
        return model
    }

    /// skillshare on every server, for the Servers area of any library.
    var herdrLibraryServers: HerdrLibraryServersModel {
        if let model = herdrLibraryServersModel { return model }
        let model = HerdrLibraryServersModel { [weak self] server in
            guard let self else { throw HerdrClient.Failure.invalidURL }
            return try self.herdrClient(for: self.herdrServer(id: server.id) ?? server)
        }
        herdrLibraryServersModel = model
        return model
    }

    /// The project whose library a bot's Skills show; nil for the one all bots on its server share.
    static func herdrLibraryScopeKey(_ botID: UUID) -> String { "herdrLibraryScope.\(botID.uuidString.lowercased())" }
    func herdrLibraryScope(for bot: Bot) -> String? { defaults.string(forKey: Self.herdrLibraryScopeKey(bot.id)).flatMap { $0.isEmpty ? nil : $0 } }
    func setHerdrLibraryScope(_ folder: String?, for bot: Bot) {
        objectWillChange.send()
        if let folder, !folder.isEmpty { defaults.set(folder, forKey: Self.herdrLibraryScopeKey(bot.id)) } else { defaults.removeObject(forKey: Self.herdrLibraryScopeKey(bot.id)) }
    }
}
