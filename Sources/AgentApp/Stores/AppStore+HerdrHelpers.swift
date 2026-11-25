import Foundation

/// A helper open in the detail column, in place of its bot's chat: `helperID` is `HerdrClient.Helper.id`.
struct HerdrHelperSelection: Hashable, Sendable {
    let botID: UUID
    let helperID: String
    var groupRuntime: String? = nil
    var parent: HerdrHelperParent { .init(botID: botID, groupRuntime: groupRuntime) }
}

/// A bot can delegate from its direct chat and independently from each of its group sessions.
struct HerdrHelperParent: Hashable, Sendable {
    let botID: UUID
    var groupRuntime: String? = nil
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

struct HerdrHelperOverview {
    struct Row: Identifiable {
        let bot: Bot
        let helper: HerdrClient.Helper
        let groupName: String?
        let id: HerdrHelperSelection
    }

    var rows: [Row] = []
    var checking: [HerdrServer] = []
    var unavailable: [HerdrServer] = []
    var disconnected: [HerdrServer] = []
    var unattributed: [(server: HerdrServer, count: Int)] = []
    var hasConnectedServer = false
    var hasBots = false
    var confirmedEmpty: Bool { hasConnectedServer && rows.isEmpty && checking.isEmpty && unavailable.isEmpty && unattributed.isEmpty }
}

/// A workspace read can confirm that a bot has no session, even when a cached model reading still has one.
struct HerdrAgentPresence: Equatable {
    let server: HerdrServer
    let session: HerdrClient.AgentRef?
    let isActive: Bool

    init(server: HerdrServer, agent: HerdrClient.Agent?) {
        self.server = server
        session = agent?.ref
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
            let direct = HerdrHelperParent(botID: bot.id)
            if herdrHelperReads[direct] == nil { checking.insert(server.id) }
            for parent in (parents[bot.id] ?? []).sorted(by: { ($0.groupRuntime ?? "") < ($1.groupRuntime ?? "") }) {
                if herdrHelperReads[parent] == .unavailable { unavailable.insert(server.id) }
                for helper in herdrHelpers[parent]?.helpers ?? [] where helper.hasOpenTask {
                    let id = HerdrHelperSelection(botID: bot.id, helperID: helper.id, groupRuntime: parent.groupRuntime)
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
        helperListingFailures = helperListingFailures.filter { $0.key.botID != bot.id }
        helperGroupNames = helperGroupNames.filter { $0.key.botID != bot.id }
        herdrStreamingParents = herdrStreamingParents.filter { $0.botID != bot.id }
        herdrHelpers = herdrHelpers.filter { $0.key.botID != bot.id }
        herdrHelperReads = herdrHelperReads.filter { $0.key.botID != bot.id }
        herdrAgentPresence[bot.id] = nil
        herdrAgentReadings[bot.id] = nil
        herdrReadiness[bot.id] = nil
    }

    /// While Overview is open, discover helpers on address servers and existing SSH connections. The normal chat
    /// watch can also reconnect SSH for an open bot, work in progress, or cached helpers.
    /// An answered helper still live is read often so its terminal disappears when it stops.
    func herdrHelperWatch() -> [String: Bool] { herdrHelperWatch(servers: herdrServers, sshIsOpen: herdrTunnels.isOpen) }

    func herdrHelperWatch(servers: [HerdrServer], sshIsOpen: (String) -> Bool) -> [String: Bool] {
        var watch: [String: Bool] = [:]
        let overviewOpen = showInfo && infoTab == .overview && selectedBot?.backend == .herdr && selectedGroup == nil && openHerdrHelper == nil
        let live = Set(herdrHelpers.compactMap { $0.value.helpers.contains(where: \.isLive) ? $0.key.botID : nil })
        let cached = Set(herdrHelpers.keys.map(\.botID))
        for bot in bots where bot.backend == .herdr && !bot.isReadOnlyArchive {
            let server = herdrServer(for: bot, in: servers)
            guard watch[server.id] != true else { continue }
            let busy = isAnswering(bot) || herdrReadiness[bot.id]?.isStarting == true
                || herdrAgentPresence[bot.id].map { $0.server == server && $0.isActive } == true || live.contains(bot.id)
            let isOpen = selectedGroup?.memberIDs.contains(bot.id) ?? (selectedBot?.id == bot.id)
            if server.kind == .local || (overviewOpen && (server.kind == .address || sshIsOpen(server.id))) || isOpen || busy || cached.contains(bot.id) {
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

    private enum HelperPollResult { case success(HerdrClient.Helpers?), unavailable }

    /// One roster finds direct and group sessions. Only parents with children need a helper listing.
    func refreshHerdrHelpers(on serverID: String) async {
        guard let server = herdrServer(id: serverID) else { return }
        let previousPresence = herdrAgentPresence, previousHelpers = herdrHelpers, previousReads = herdrHelperReads
        let client = try? herdrClient(for: server)
        let workspace = try? await client?.workspace()
        guard !Task.isCancelled, herdrServer(id: serverID) == server else { return }
        let group = herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        var results: [HerdrHelperParent: HelperPollResult] = [:]
        var targets: [(HerdrHelperParent, HerdrClient.Agent?)] = []
        let botIDs = Set(bots.map(\.id))
        var presence = herdrAgentPresence.filter { botIDs.contains($0.key) }
        var readiness: [UUID: HerdrAgentReadiness?] = [:]
        var groupNames: [HerdrHelperParent: String] = [:]
        for bot in group {
            let direct = workspace.flatMap { client?.liveAgent(named: HerdrBackend.agentName(botName: bot.name, botID: bot.id), in: $0) }
            if let workspace, previousPresence[bot.id] == herdrAgentPresence[bot.id] {
                presence[bot.id] = HerdrAgentPresence(server: server, agent: direct)
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
            }
        }
        if presence != herdrAgentPresence { herdrAgentPresence = presence }
        if workspace != nil { noteHerdrReadiness(readiness, watched: group, on: server) }

        for (parent, agent) in targets {
            guard !streamOwnsHerdrHelpers(parent) else { continue }
            guard let client, let workspace else {
                results[parent] = .unavailable
                continue
            }
            do {
                var list: HerdrClient.Helpers?
                if let agent { list = try await client.helpers(of: agent, in: workspace) }
                results[parent] = .success(list?.helpers.isEmpty == false ? list : nil)
            } catch {
                results[parent] = .unavailable
            }
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
                reads[parent] = .polled
            case .unavailable:
                helperListingFailures[parent, default: 0] += 1
                if helperListingFailures[parent, default: 0] >= Self.herdrHelperFailureLimit { found[parent] = nil }
                reads[parent] = .unavailable
            }
        }
        if found != herdrHelpers { herdrHelpers = found }
        if reads != herdrHelperReads { herdrHelperReads = reads }
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
            let shown = list.helpers.isEmpty ? nil : list
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
        open(bot)
        openHerdrHelper = HerdrHelperSelection(botID: bot.id, helperID: helper.id, groupRuntime: groupRuntime)
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
    func herdrHelperLog(_ helper: HerdrClient.AgentRef, core: String, of bot: Bot) async throws -> HerdrClient.HelperLog {
        try await herdrClient(for: herdrServer(for: bot)).helperLog(core: core, helper: helper)
    }
}
