import Foundation

/// A helper open in the detail column, in place of its bot's chat: `helperID` is `HerdrClient.Helper.id`.
struct HerdrHelperSelection: Hashable, Sendable {
    let botID: UUID
    let helperID: String
    var groupRuntime: String? = nil
    var source: HerdrHelperSource? = nil
    var archive: HerdrHelperSource? = nil
    var parent: HerdrHelperParent { .init(botID: botID, groupRuntime: groupRuntime, source: source, archive: archive) }
}

/// A bot can delegate from its direct chat and independently from each of its group sessions.
struct HerdrHelperParent: Hashable, Sendable {
    let botID: UUID
    var groupRuntime: String? = nil
    var source: HerdrHelperSource? = nil
    var archive: HerdrHelperSource? = nil

    func selection(for helper: HerdrClient.Helper) -> HerdrHelperSelection {
        .init(botID: botID, helperID: helper.id, groupRuntime: groupRuntime, source: source, archive: archive)
    }

    func children(of session: HerdrClient.AgentRef, core: String) -> Self {
        .init(botID: botID, groupRuntime: groupRuntime, source: .init(core: core, session: session), archive: archive)
    }
}

struct HerdrHelperSource: Hashable, Sendable {
    let core: String
    let session: HerdrClient.AgentRef
}

struct SidebarHelperSession: Identifiable {
    let id: HerdrHelperSelection
    let helper: HerdrClient.Helper
    let core: String
    let depth: Int
    let hasChildren: Bool
}

extension Dictionary where Key == HerdrHelperParent {
    /// The direct chat's snapshot, used by the sidebar and per-bot details.
    subscript(botID: UUID) -> Value? {
        get { self[HerdrHelperParent(botID: botID)] }
        set { self[HerdrHelperParent(botID: botID)] = newValue }
    }
}

/// A successful read can contain zero helpers. A missing entry means the first read is pending.
enum HerdrHelperRead { case polled, streamed, unavailable }

enum HerdrHelperRoster: Equatable {
    case available(unattributed: Int), unavailable
}

struct HerdrCodejobRead {
    let server: HerdrServer
    let hosts: [HerdrClient.CodejobActivity.Host]?
    let observed: ContinuousClock.Instant
    var unsupported = false

    // Use the beginning of the request. A delayed reply cannot renew an old observation.
    var isFresh: Bool { ContinuousClock.now - observed < .seconds(25) }
}

struct HerdrCodejobRow: Identifiable {
    struct ID: Hashable {
        let server: String
        let host: String
        let owner: UUID
        let job: String
    }
    let id: ID
    let bot: Bot
    let job: HerdrClient.CodejobActivity.Job
}

struct HerdrHelperOverview {
    struct Row: Identifiable {
        let bot: Bot
        let helper: HerdrClient.Helper
        let groupName: String?
        let id: HerdrHelperSelection
    }

    var rows: [Row] = []
    var codejobs: [HerdrCodejobRow] = []
    var withoutDetachedActivity: [HerdrServer] = []
    var unavailableCodejobHosts: [String] = []
    var checking: [HerdrServer] = []
    var unavailable: [HerdrServer] = []
    var disconnected: [HerdrServer] = []
    var unattributed: [(server: HerdrServer, count: Int)] = []
    var hasConnectedServer = false
    var hasBots = false
    var confirmedEmpty: Bool {
        hasConnectedServer && rows.isEmpty && codejobs.isEmpty && checking.isEmpty
            && unavailable.isEmpty && unattributed.isEmpty && unavailableCodejobHosts.isEmpty
    }
}

/// A workspace read can confirm that a bot has no session, even when a cached model reading still has one.
struct HerdrAgentPresence: Equatable {
    let server: HerdrServer
    let session: HerdrClient.AgentRef?
    let isActive: Bool
    let usage: HerdrClient.SessionUsage?
    let template: String?
    let program: String?
    let nextTemplate: String?

    init(server: HerdrServer, agent: HerdrClient.Agent?, program: String? = nil, nextTemplate: String? = nil) {
        self.server = server
        session = agent?.ref
        usage = agent?.sessionUsage
        template = agent?.template
        self.program = program
        self.nextTemplate = nextTemplate
        isActive = agent?.isStarting == true || agent?.status?.state == "working" || agent?.status?.state == "blocked"
    }
}

/// Helper agents of Herdr bots. A bot's agent starts them itself (`swarmhub-herdr helper start`, when the bot's
/// "Can start helper agents" switch told it how); the app shows them under the bot while the server lists them and
/// lets the person read one. Nothing here starts, steers or stops a helper.
extension AppStore {
    // MARK: The switch

    /// `UserDefaults`: a bot's own choice. Unset, every Herdr bot may start helpers: a helper is a sub-agent of its
    /// bot, and the server's helper settings limit what one runs on and how many an agent may have.
    static func herdrHelpersKey(_ botID: UUID) -> String { "herdrHelpers.\(botID.uuidString.lowercased())" }

    func startsHerdrHelpers(_ bot: Bot) -> Bool {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return false }
        return defaults.object(forKey: Self.herdrHelpersKey(bot.id)) as? Bool ?? true
    }

    func setStartsHerdrHelpers(_ on: Bool, for bot: Bot) { defaults.set(on, forKey: Self.herdrHelpersKey(bot.id)); objectWillChange.send() }

    // MARK: Reading them

    func hasActiveCodingAgent(_ bot: Bot) -> Bool {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return false }
        return herdrHasUnansweredHelpers(bot) || herdrPresence(for: bot)?.isActive == true
            || codejobs(for: bot, on: herdrServer(for: bot)).contains { $0.job.isWorking }
    }

    /// Keep workers on the bot and workspace that own their registration.
    var sidebarCodejobs: [UUID: [HerdrCodejobRow]] {
        let owners = Set(herdrCodejobReads.values.filter(\.isFresh).flatMap { read in
            (read.hosts ?? []).flatMap { $0.jobs.map(\.owner) }
        })
        guard !owners.isEmpty else { return [:] }
        let servers = herdrServers
        var rows: [UUID: [HerdrCodejobRow]] = [:]
        for bot in bots where owners.contains(bot.id) && bot.backend == .herdr && !bot.isReadOnlyArchive {
            let jobs = codejobs(for: bot, on: herdrServer(for: bot, in: servers))
            if !jobs.isEmpty { rows[bot.id] = jobs }
        }
        return rows
    }

    private func codejobs(for bot: Bot, on server: HerdrServer) -> [HerdrCodejobRow] {
        guard let read = herdrCodejobReads[server.id], read.server == server, read.isFresh,
              let hosts = read.hosts else { return [] }
        return hosts.flatMap { host in
            host.jobs.filter { $0.owner == bot.id }.map { job in
                .init(id: .init(server: server.id, host: host.host, owner: bot.id, job: job.job), bot: bot, job: job)
            }
        }
    }

    func sidebarSessions(under root: HerdrHelperParent, collapsed: Set<HerdrHelperSelection>) -> [SidebarHelperSession] {
        guard let first = herdrHelpers[root] else { return [] }
        var pending = first.sidebarSessions.reversed().map { (root, $0, 0) }
        var seen: Set<HerdrClient.AgentRef> = [first.parent]
        var rows: [SidebarHelperSession] = []
        while let (parent, helper, depth) = pending.popLast() {
            guard seen.insert(helper.ref).inserted else { continue }
            let key = parent.children(of: helper.ref, core: first.core)
            let children = herdrHelpers[key]?.sidebarSessions ?? []
            let selection = parent.selection(for: helper)
            rows.append(.init(id: selection, helper: helper, core: first.core, depth: depth, hasChildren: !children.isEmpty))
            if !collapsed.contains(selection) {
                pending += children.reversed().map { (key, $0, depth + 1) }
            }
        }
        return rows
    }

    func delegatingSession(for selection: HerdrHelperSelection) -> SidebarHelperSession? {
        guard let source = selection.source else { return nil }
        let root = HerdrHelperParent(botID: selection.botID, groupRuntime: selection.groupRuntime, archive: selection.archive)
        guard herdrHelpers[root]?.core == source.core else { return nil }
        return sidebarSessions(under: root, collapsed: []).first { $0.helper.ref == source.session }
    }

    func groupOwningHelper(_ selection: HerdrHelperSelection, of bot: Bot) -> GroupChat? {
        guard bot.id == selection.botID, let runtime = selection.groupRuntime else { return nil }
        return groups.first { $0.memberIDs.contains(bot.id) && approvalAgentNames(for: bot, in: $0).contains(runtime) }
    }

    func herdrHasUnansweredHelpers(_ bot: Bot, parent: HerdrClient.AgentRef? = nil) -> Bool {
        herdrHelpers.contains { key, list in
            key.botID == bot.id && (parent == nil || list.parent == parent) && list.helpers.contains { $0.isLive && $0.answered != true }
        }
    }

    private func groupHelperParents(of bot: Bot) -> [HerdrHelperParent: String] {
        var names: [HerdrHelperParent: String] = [:]
        for group in groups where group.memberIDs.contains(bot.id) {
            // Both the stored legacy session and the current send route can still own live children.
            let sessions = [turnSessionID(in: group, bot: bot), group.session(for: bot.id)].compactMap { $0 }
            for session in Set(sessions) {
                if let name = HerdrBackend.groupRuntimeName(sessionID: session, botID: bot.id) {
                    names[.init(botID: bot.id, groupRuntime: name)] = group.name
                }
            }
        }
        return names
    }

    var herdrHelperOverview: HerdrHelperOverview {
        var result = HerdrHelperOverview()
        let servers = herdrServers
        let watch = herdrHelperWatch(servers: servers, sshIsOpen: herdrTunnels.isOpen)
        var included: Set<String> = [], checking: Set<String> = [], unavailable: Set<String> = []
        let parents = Dictionary(grouping: herdrHelperReads.keys, by: \.botID)
        for bot in bots where bot.backend == .herdr && !bot.isReadOnlyArchive {
            result.hasBots = true
            let server = herdrServer(for: bot, in: servers)
            guard watch[server.id] != nil else {
                if server.kind == .ssh && !result.disconnected.contains(server) { result.disconnected.append(server) }
                continue
            }
            included.insert(server.id)
            result.codejobs += codejobs(for: bot, on: server)
            let direct = HerdrHelperParent(botID: bot.id)
            if herdrHelperReads[direct] == nil { checking.insert(server.id) }
            for parent in (parents[bot.id] ?? []).sorted(by: { ($0.groupRuntime ?? "") < ($1.groupRuntime ?? "") }) {
                if herdrHelperReads[parent] == .unavailable { unavailable.insert(server.id) }
                for helper in herdrHelpers[parent]?.helpers ?? [] where helper.hasOpenTask {
                    let id = parent.selection(for: helper)
                    result.rows.append(.init(bot: bot, helper: helper, groupName: helperGroupNames[parent] ?? parent.groupRuntime, id: id))
                }
            }
        }
        for server in servers where included.contains(server.id) {
            switch helperRosters[server.id] {
            case .available(let count):
                if count > 0 { result.unattributed.append((server, count)) }
            case .unavailable: unavailable.insert(server.id)
            case nil: checking.insert(server.id)
            }
            guard let read = herdrCodejobReads[server.id], read.server == server else {
                checking.insert(server.id)
                continue
            }
            if read.unsupported {
                result.withoutDetachedActivity.append(server)
                continue
            }
            guard read.isFresh, let hosts = read.hosts else {
                unavailable.insert(server.id)
                continue
            }
            result.unavailableCodejobHosts += hosts.filter { !$0.complete }.map { "\(server.name) · \($0.host)" }
        }
        result.hasConnectedServer = !included.isEmpty
        result.checking = servers.filter { checking.contains($0.id) && !unavailable.contains($0.id) }
        result.unavailable = servers.filter { unavailable.contains($0.id) }
        return result
    }

    func herdrTerminalSession(for bot: Bot) -> HerdrClient.AgentRef? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return nil }
        if let presence = herdrAgentPresence[bot.id] { return presence.server == herdrServer(for: bot) ? presence.session : nil }
        return herdrAgentReadings[bot.id]?.session
    }

    func herdrPresence(for bot: Bot) -> HerdrAgentPresence? {
        guard let presence = herdrAgentPresence[bot.id], presence.server == herdrServer(for: bot) else { return nil }
        return presence
    }

    func forgetHerdrAgentState(for bot: Bot) {
        for groupID in herdrPromptBook.groupSignIns.keys { herdrPromptBook.groupSignIns[groupID]?[bot.id] = nil }
        helperListingFailures = helperListingFailures.filter { $0.key.botID != bot.id }
        archivedHelperRevisions = archivedHelperRevisions.filter { $0.key.botID != bot.id }
        helperGroupNames = helperGroupNames.filter { $0.key.botID != bot.id }
        herdrStreamingParents = herdrStreamingParents.filter { $0.botID != bot.id }
        herdrHelpers = herdrHelpers.filter { $0.key.botID != bot.id }
        herdrHelperReads = herdrHelperReads.filter { $0.key.botID != bot.id }
        herdrAgentPresence[bot.id] = nil
        herdrReadingUpdated[bot.id] = nil
        herdrAgentReadings[bot.id] = nil
        herdrReadiness[bot.id] = nil
    }

    /// Discover sidebar sessions on local, address and already-connected SSH servers. An open chat,
    /// work in progress or previously observed helpers can also reconnect an SSH workspace.
    /// An answered helper still live is read often so its terminal disappears when it stops.
    func herdrHelperWatch() -> [String: Bool] { herdrHelperWatch(servers: herdrServers, sshIsOpen: herdrTunnels.isOpen) }

    func herdrHelperWatch(servers: [HerdrServer], sshIsOpen: (String) -> Bool) -> [String: Bool] {
        var watch: [String: Bool] = [:]
        let live = Set(herdrHelpers.compactMap { $0.value.helpers.contains(where: \.isLive) ? $0.key.botID : nil })
        let cached = Set(herdrHelpers.keys.filter { $0.archive == nil }.map(\.botID))
        for bot in bots where bot.backend == .herdr && !bot.isReadOnlyArchive {
            let server = herdrServer(for: bot, in: servers)
            guard watch[server.id] != true else { continue }
            let awaitsHelper = bot.promotedHelper.map { $0.pendingAfter != nil && $0.serverID == server.id } ?? false
            let busy = awaitsHelper || isAnswering(bot) || herdrReadiness[bot.id]?.isStarting == true
                || herdrAgentPresence[bot.id].map { $0.server == server && $0.isActive } == true || live.contains(bot.id)
                || codejobs(for: bot, on: server).contains { $0.job.isWorking }
            let isOpen = selectedGroup?.memberIDs.contains(bot.id) ?? (selectedBot?.id == bot.id)
            if server.kind != .ssh || sshIsOpen(server.id) || isOpen || busy || cached.contains(bot.id) {
                watch[server.id] = busy
            }
        }
        return watch
    }

    /// Reads the watched bots' helpers until the app quits. One request per server finds each bot's agent and whether
    /// it has helpers at all; only an agent that has some costs a second one.
    func startHerdrHelperPolling(often: Duration = .seconds(3), seldom: Duration = .seconds(12)) {
        guard launchWorkEnabled, herdrHelperPoll == nil else { return }
        herdrHelperPoll = Task { [weak self] in
            let clock = ContinuousClock()
            var last: [String: ContinuousClock.Instant] = [:]
            var reading: [String: Task<Void, Never>] = [:]
            defer { for task in reading.values { task.cancel() } }
            while !Task.isCancelled, let store = self {
                let servers = store.herdrServers
                let watch = store.herdrHelperWatch(servers: servers, sshIsOpen: store.herdrTunnels.isOpen)
                // A newly watched server needs a fresh roster before confirming an empty overview.
                let watchedRosters = store.helperRosters.filter { watch[$0.key] != nil }
                if watchedRosters != store.helperRosters { store.helperRosters = watchedRosters }
                // Publish expiry even if a network read stalls or the SSH forward closes.
                for (id, read) in store.herdrCodejobReads where read.hosts != nil && (!read.isFresh || watch[id] == nil) {
                    store.herdrCodejobReads[id] = HerdrCodejobRead(server: read.server, hosts: nil, observed: clock.now)
                }
                last = last.filter { watch[$0.key] != nil }
                for (server, busy) in watch where reading[server] == nil {
                    guard last[server].map({ clock.now - $0 >= (busy ? often : seldom) }) ?? true else { continue }
                    reading[server] = Task {
                        await store.refreshHerdrHelpers(on: server)
                        last[server] = clock.now
                        reading[server] = nil
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// How many reads of a server may fail in a row before its bots' helpers are taken off the screen.
    static let herdrHelperFailureLimit = 5

    private enum HelperPollResult: Sendable { case success(HerdrClient.Helpers?), unavailable }

    /// One roster finds direct and group sessions. Only parents with children need a helper listing.
    func refreshHerdrHelpers(on serverID: String) async {
        guard let server = herdrServer(id: serverID) else { return }
        let previousPresence = herdrAgentPresence, previousHelpers = herdrHelpers, previousReads = herdrHelperReads
        let client = try? herdrClient(for: server)
        let observed = ContinuousClock.now
        let workspace: HerdrClient.Workspace?
        var needsLogin = false
        do { workspace = try await client?.workspace(includingCodejobs: true) }
        catch {
            workspace = nil
            needsLogin = server.kind == .ssh && HerdrTunnel.offersPassword(error)
        }
        guard !Task.isCancelled, herdrServer(id: serverID) == server else { return }
        let request = needsLogin && !herdrTunnels.isOpen(serverID) ? server : nil
        if sshLoginRequests[serverID] != request { sshLoginRequests[serverID] = request }
        // A successful older roster predates detached activity. Malformed data, a failed GET,
        // or an omitted feed from a level-3 bridge still counts as an incomplete observation.
        let unsupported = workspace.map { ($0.bridge?.api ?? 0) < 3 && $0.codejobActivity == nil } ?? false
        herdrCodejobReads[server.id] = HerdrCodejobRead(server: server, hosts: workspace?.codejobActivity?.hosts,
                                                       observed: observed, unsupported: unsupported)
        let group = herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        var results: [HerdrHelperParent: HelperPollResult] = [:]
        var targets: [(HerdrHelperParent, HerdrClient.Agent?)] = []
        var archiveTargets: [HerdrHelperParent: HerdrClient.ArchivedHelperParent] = [:]
        let archives = workspace?.archivedHelperParents ?? []
        let rootArchives = Dictionary(grouping: archives.filter { $0.delegatedBy == nil }, by: \.agent)
        let directNames = Dictionary(grouping: group.map { HerdrBackend.agentName(botName: $0.name, botID: $0.id) },
                                     by: HerdrClient.suffix(of:))
        let renamedArchives = Dictionary(grouping: rootArchives.keys.filter { name in
            let registered = directNames[HerdrClient.suffix(of: name)]
            return registered?.count == 1 && registered?.first != name
        }, by: HerdrClient.suffix(of:))
        var nestedArchives: [HerdrHelperSource: [HerdrClient.ArchivedHelperParent]] = [:]
        for archive in archives {
            if let owner = archive.delegatedBy {
                nestedArchives[.init(core: archive.core, session: owner), default: []].append(archive)
            }
        }
        let botIDs = Set(bots.map(\.id))
        var presence = herdrAgentPresence.filter { botIDs.contains($0.key) }
        var readiness: [UUID: HerdrAgentReadiness?] = [:]
        var groupNames: [HerdrHelperParent: String] = [:]
        let usableTemplates = workspace?.templates.filter { $0.error == nil } ?? []
        for bot in group {
            let direct = workspace.flatMap { client?.liveAgent(named: HerdrBackend.agentName(botName: bot.name, botID: bot.id), in: $0) }
            if let workspace, previousPresence[bot.id] == herdrAgentPresence[bot.id] {
                let nextTemplate = herdrTemplate(for: bot)
                let template: HerdrClient.Template?
                if let direct {
                    template = workspace.templates.first { $0.name == direct.template }
                } else {
                    template = HerdrAgentReading.template(own: nextTemplate, shared: nil, in: usableTemplates).template
                }
                presence[bot.id] = HerdrAgentPresence(server: server, agent: direct, program: template?.programName, nextTemplate: nextTemplate)
                if let direct, var reading = herdrAgentReadings[bot.id], reading.session == direct.ref,
                   reading.core == workspace.core, reading.codexSessionModel != direct.codexSessionModel {
                    reading.codexSessionModel = direct.codexSessionModel
                    herdrReadingUpdated[bot.id] = .now
                    herdrAgentReadings[bot.id] = reading
                }
                readiness[bot.id] = .some(HerdrAgentReadiness(direct, in: workspace))
            }
            let names = groupHelperParents(of: bot)
            groupNames.merge(names) { _, new in new }
            for parent in [HerdrHelperParent(botID: bot.id)] + Array(names.keys) {
                if let name = parent.groupRuntime {
                    targets.append((parent, workspace?.agents.first { $0.isLive && $0.parent == nil && $0.name == name }))
                } else {
                    targets.append((parent, direct))
                }
                let name = parent.groupRuntime ?? HerdrBackend.agentName(botName: bot.name, botID: bot.id)
                let priorNames = parent.groupRuntime == nil ? renamedArchives[HerdrClient.suffix(of: name)] ?? [] : []
                for archive in ([name] + priorNames).flatMap({ rootArchives[$0] ?? [] }) {
                    let source = HerdrHelperSource(core: archive.core, session: archive.session)
                    let key = HerdrHelperParent(botID: bot.id, groupRuntime: parent.groupRuntime, archive: source)
                    archiveTargets[key] = archive
                    groupNames[key] = names[parent]
                    targets.append((key, nil))
                }
            }
        }
        if presence != herdrAgentPresence { herdrAgentPresence = presence }
        if workspace != nil { noteHerdrReadiness(readiness, watched: group, on: server) }

        if let workspace, let core = workspace.core {
            let live = workspace.agents.filter { $0.isLive && $0.parent != nil }
            let children = Dictionary(grouping: live) { $0.parent }
            let saved = Set(workspace.helperSessionParents ?? [])
            var visited = Set(targets.compactMap { $0.1.map { HerdrHelperSource(core: core, session: $0.ref) } })
            var cursor = 0
            while cursor < targets.count {
                let (root, owner) = targets[cursor]
                cursor += 1
                guard let ref = owner?.ref ?? archiveTargets[root]?.session else { continue }
                let ownerCore = archiveTargets[root]?.core ?? core
                let source = HerdrHelperSource(core: ownerCore, session: ref)
                for archive in nestedArchives[source] ?? [] {
                    let child = HerdrHelperSource(core: ownerCore, session: archive.session)
                    guard visited.insert(child).inserted else { continue }
                    let key = root.children(of: archive.session, core: ownerCore)
                    archiveTargets[key] = archive
                    groupNames[key] = groupNames[root]
                    targets.append((key, nil))
                }
                guard ownerCore == core else { continue }
                for child in children[ref] ?? [] where visited.insert(.init(core: core, session: child.ref)).inserted {
                    guard children[child.ref] != nil || saved.contains(child.ref) || nestedArchives[.init(core: core, session: child.ref)] != nil else { continue }
                    let key = root.children(of: child.ref, core: core)
                    groupNames[key] = groupNames[root]
                    targets.append((key, child))
                }
            }
        } else if workspace == nil {
            // Keep the same grace period for nested sessions during a temporary disconnect.
            let watched = Set(group.map(\.id))
            for key in previousHelpers.keys where (key.source != nil || key.archive != nil) && watched.contains(key.botID) {
                targets.append((key, nil))
            }
        }

        for (parent, agent) in targets where archiveTargets[parent] == nil {
            guard !streamOwnsHerdrHelpers(parent) else { continue }
            guard let client, let workspace else {
                results[parent] = .unavailable
                continue
            }
            do {
                var list: HerdrClient.Helpers?
                if let agent {
                    let readingChat = parent.groupRuntime == nil && selectedGroup == nil && selectedBot?.id == parent.botID
                    let previous = herdrHelpers[parent]
                    let sameLaunch = previous?.parent == agent.ref && previous?.core == workspace.core
                    list = try await client.helpers(of: agent, in: workspace, includeLastResult: readingChat || sameLaunch)
                    if let list, list.parent != agent.ref || (workspace.core != nil && workspace.core != list.core) {
                        results[parent] = .unavailable
                        continue
                    }
                }
                results[parent] = .success(list?.sidebarSessions.isEmpty == false ? list : nil)
            } catch {
                results[parent] = .unavailable
            }
        }
        if let client, let workspace, !archiveTargets.isEmpty {
            let saved = await readArchivedHelpers(archiveTargets, previous: previousHelpers, workspace: workspace, client: client)
            results.merge(saved) { _, fresh in fresh }
        }
        guard !Task.isCancelled, herdrServer(id: serverID) == server else { return }
        if workspace == nil { herdrHelperFailures[serverID, default: 0] += 1 }
        else { herdrHelperFailures[serverID] = nil }
        let discard = client == nil || herdrHelperFailures[serverID, default: 0] >= Self.herdrHelperFailureLimit
        let current = herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        if discard && workspace == nil {
            for bot in current where previousPresence[bot.id] == herdrAgentPresence[bot.id] {
                presence[bot.id] = HerdrAgentPresence(server: server, agent: nil)
                readiness[bot.id] = .some(nil)
            }
            if presence != herdrAgentPresence { herdrAgentPresence = presence }
            noteHerdrReadiness(readiness, watched: current, on: server)
        }
        let bound = Set(current.map(\.id))
        let remainingBots = Set(bots.filter { $0.backend == .herdr && !$0.isReadOnlyArchive }.map(\.id))
        let expected = Set(targets.map { $0.0 })
        func keep(_ parent: HerdrHelperParent) -> Bool {
            remainingBots.contains(parent.botID) && (!bound.contains(parent.botID) || expected.contains(parent) || herdrStreamingParents.contains(parent))
        }
        archivedHelperRevisions = archivedHelperRevisions.filter { keep($0.key) }
        var found = herdrHelpers.filter { keep($0.key) }
        var reads = herdrHelperReads.filter { keep($0.key) }
        helperListingFailures = helperListingFailures.filter { keep($0.key) }
        let labels = helperGroupNames.filter { keep($0.key) && !bound.contains($0.key.botID) }.merging(groupNames) { _, new in new }
        if labels != helperGroupNames { helperGroupNames = labels }
        let roster: HerdrHelperRoster
        if let workspace {
            let known = Set(targets.compactMap { $0.1?.ref })
            let count = workspace.agents.filter { $0.isLive && $0.parent.map { !known.contains($0) } == true }.count
            roster = .available(unattributed: count)
        } else { roster = .unavailable }
        if helperRosters[serverID] != roster { helperRosters[serverID] = roster }

        // A stream may take ownership while a sibling listing request is in flight.
        for (parent, result) in results where bound.contains(parent.botID) && !streamOwnsHerdrHelpers(parent)
            && found[parent] == previousHelpers[parent] && reads[parent] == previousReads[parent] {
            switch result {
            case .success(let list):
                helperListingFailures[parent] = nil
                found[parent] = list
                archivedHelperRevisions[parent] = archiveTargets[parent]?.revision
                reads[parent] = .polled
            case .unavailable:
                helperListingFailures[parent, default: 0] += 1
                if helperListingFailures[parent, default: 0] >= Self.herdrHelperFailureLimit { found[parent] = nil }
                reads[parent] = .unavailable
            }
        }
        if let selected = openHerdrHelper, selected.archive == nil,
           let old = previousHelpers[selected.parent],
           (found[selected.parent]?.core != old.core || found[selected.parent]?.parent != old.parent
            || found[selected.parent]?.sidebarSessions.contains(where: { $0.id == selected.helperID }) != true),
           let replacement = found.first(where: { key, list in
               key.botID == selected.botID && key.groupRuntime == selected.groupRuntime && key.archive != nil
                   && list.core == old.core && list.parent == old.parent && list.sidebarSessions.contains { $0.id == selected.helperID }
           }) {
            var moved = selected
            moved.archive = replacement.key.archive
            openHerdrHelper = moved
        }
        if found != herdrHelpers { herdrHelpers = found }
        if reads != herdrHelperReads { herdrHelperReads = reads }
        if let workspace, let client { await collectPromotedReplies(on: server, workspace: workspace, client: client) }
    }

    /// Share a few concurrent reads over the existing connection when a Mac first discovers old sessions.
    private func readArchivedHelpers(_ targets: [HerdrHelperParent: HerdrClient.ArchivedHelperParent],
                                     previous: [HerdrHelperParent: HerdrClient.Helpers],
                                     workspace: HerdrClient.Workspace, client: HerdrClient) async -> [HerdrHelperParent: HelperPollResult] {
        let liveParents = Set(workspace.agents.filter(\.isLive).compactMap(\.parent))
        return await withTaskGroup(of: (HerdrHelperParent, HelperPollResult).self) { group in
            var results: [HerdrHelperParent: HelperPollResult] = [:]
            var pending = 0
            for (parent, archive) in targets {
                if Task.isCancelled { break }
                let hasLiveChildren = archive.core == workspace.core && liveParents.contains(archive.session)
                if !hasLiveChildren, archivedHelperRevisions[parent] == archive.revision,
                   let cached = previous[parent], cached.helpers.isEmpty {
                    results[parent] = .success(cached)
                    continue
                }
                if pending == 6, let (key, result) = await group.next() {
                    results[key] = result
                    pending -= 1
                }
                group.addTask {
                    guard let list = try? await client.helpers(of: archive.session, core: archive.core),
                          list.parent == archive.session, list.core == archive.core else { return (parent, .unavailable) }
                    return (parent, .success(list.sidebarSessions.isEmpty ? nil : list))
                }
                pending += 1
            }
            for await (key, result) in group { results[key] = result }
            return results
        }
    }

    private func streamOwnsHerdrHelpers(_ parent: HerdrHelperParent) -> Bool {
        herdrStreamingParents.contains(parent) && herdrHelperReads[parent] == .streamed
    }

    /// What a running turn on the event stream says beside its reply: whether the stream is delivering, and the
    /// agent's helpers whenever they change. Helpers the stream no longer lists leave the screen like polled ones.
    func herdrLive(_ note: HerdrClient.LiveNote, botID: UUID, groupRuntime: String? = nil) {
        let parent = HerdrHelperParent(botID: botID, groupRuntime: groupRuntime)
        switch note {
        case .following(let on): if on { herdrStreamingParents.insert(parent) } else { herdrStreamingParents.remove(parent) }
        case .helpers(let list):
            guard let list else {
                // No listing was available. Retain the rows and let polling retry this parent.
                if herdrHelperReads[parent] != .unavailable { herdrHelperReads[parent] = .unavailable }
                return
            }
            helperListingFailures[parent] = nil
            let shown = list.sidebarSessions.isEmpty ? nil : list
            if herdrHelpers[parent] != shown { herdrHelpers[parent] = shown }
            if herdrHelperReads[parent] != .streamed { herdrHelperReads[parent] = .streamed }
        }
    }

    // MARK: Looking into one

    func isOpen(_ helper: HerdrClient.Helper, of bot: Bot) -> Bool {
        openHerdrHelper == HerdrHelperSelection(botID: bot.id, helperID: helper.id) && selectedBot?.id == bot.id && selectedGroup == nil
    }

    /// Shows the helper's read-only view in place of its bot's chat; opening the bot (or any chat) shows the chat again.
    func open(_ helper: HerdrClient.Helper, of bot: Bot, groupRuntime: String? = nil) {
        open(bot, helper: HerdrHelperSelection(botID: bot.id, helperID: helper.id, groupRuntime: groupRuntime))
    }

    func openHelperParent(_ selection: HerdrHelperSelection, of bot: Bot) -> Bool {
        guard selection.botID == bot.id else { return false }
        if selection.groupRuntime != nil {
            guard let group = groupOwningHelper(selection, of: bot)
            else { return false }
            open(group)
            composerFocus = group.id
        } else {
            open(bot)
            composerFocus = bot.id
        }
        return true
    }

    /// Only send through the session that owns this helper. An obsolete group runtime cannot receive a steer.
    func guideHelper(_ helper: HerdrClient.Helper, selection: HerdrHelperSelection, of bot: Bot, instruction: String) -> Bool {
        let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, selection.archive == nil, selection.botID == bot.id, selection.helperID == helper.id,
              herdrHelperReads[selection.parent] != .unavailable,
              herdrHelpers[selection.parent]?.helpers.contains(where: { $0.id == helper.id && $0.isLive }) == true
        else { return false }
        let owner = delegatingSession(for: selection).map { "the helper delegated by “\($0.helper.name)” named" } ?? "your helper"
        let text = "Please steer \(owner) “\(helper.name)” with this instruction:\n\(words)"
        if let runtime = selection.groupRuntime {
            guard let group = groups.first(where: { group in
                group.memberIDs.contains(bot.id) && HerdrBackend.groupRuntimeName(sessionID: turnSessionID(in: group, bot: bot), botID: bot.id) == runtime
            }), send(text: text, to: group, recipientIDs: [bot.id], queueChoice: true, usesComposerReply: false) else { return false }
            open(group)
        } else {
            guard send(text: text, bot: bot, conversation: bot, replyToID: nil, waitWhenFull: true) else { return false }
            open(bot)
        }
        return true
    }

    func stopHelper(_ helper: HerdrClient.Helper, selection: HerdrHelperSelection, of bot: Bot) async throws {
        let server = herdrServer(for: bot)
        guard selection.botID == bot.id, selection.helperID == helper.id,
              let snapshot = herdrHelpers[selection.parent] else {
            throw BackendError.unavailable("This helper is no longer available.")
        }
        let client = try herdrClient(for: server)
        let current = try await client.helpers(of: snapshot.parent)
        guard current.core == snapshot.core, current.parent == snapshot.parent,
              herdrServer(for: bot) == server,
              current.helpers.contains(where: { $0.ref == helper.ref && $0.isLive }) else {
            throw BackendError.unavailable("The helper is no longer running in this session.")
        }
        try await client.end(helper.ref)
    }

    /// The helper's own session as events (`HerdrEvents.swift`): its tasks, replies, tool calls and the reply it is writing.
    func herdrHelperEvents(_ helper: HerdrClient.AgentRef, of bot: Bot) throws -> AsyncThrowingStream<HerdrEvent, Error> {
        try herdrClient(for: herdrServer(for: bot)).events(of: helper)
    }

    /// The helper's terminal as text, which the event stream does not carry; nil when Core has none any more.
    func herdrHelperScreen(_ helper: HerdrClient.AgentRef, of bot: Bot) async -> String? {
        guard let client = try? herdrClient(for: herdrServer(for: bot)) else { return nil }
        return try? await client.screen(of: helper)
    }

    /// The helper's saved task and replies, its tool calls and its terminal, read from its bot's server.
    func herdrHelperLog(_ helper: HerdrClient.AgentRef, core: String, of bot: Bot, includeScreen: Bool = true) async throws -> HerdrClient.HelperLog {
        try await herdrClient(for: herdrServer(for: bot)).helperLog(core: core, helper: helper, includeScreen: includeScreen)
    }
}
