import AppKit
import SwiftUI
import Testing
@testable import AgentApp

private let suppliedCodejobRosters = ProcessInfo.processInfo.environment["SWARMHUB_CODEJOB_TEST_ROSTERS"].map { URL(fileURLWithPath: $0) }

private func codejobFixture(_ arguments: [String]) async throws -> (status: Int32, output: String) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = Process()
    fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    fixture.arguments = [root.appendingPathComponent("HerdrWorkspace/tests/codejob_activity.py").path, "--integration"] + arguments
    return try await runToEnd(fixture, timeout: arguments.contains("--check-prerequisites") ? 10 : 120)
}

private let detachedRosterFixture = Testing.ConditionTrait.enabled("Requires bridge-captured rosters or the candidate bridge, sb-codejob and hc.") {
    if suppliedCodejobRosters != nil { return true }
    let check = try await codejobFixture(["--check-prerequisites"])
    if shellSuiteSkipped(check.status, check.output) { return false }
    try #require(check.status == 0, "Detached fixture configuration failed: \(check.output)")
    return true
}

@MainActor @Suite struct HerdrCodingAgentTests {
    private let parent = HerdrClient.AgentRef(address: "parent", createdMs: 1)
    private let helper = HerdrClient.Helper(address: "child", createdMs: 2, name: "Build Scout", modelLabel: "Atlas Pro",
                                            task: "Verify build settings\nReport the results", state: "live", status: .init(state: "working"))

    @Test func activeHelpersKeepTheBotWorkingAfterItsReply() {
        let store = makeStore()
        let bot = Bot(name: "Bot fixture", backend: .herdr)
        store.bots = [bot]
        #expect(!store.hasActiveCodingAgent(bot) && !store.isWorking(bot))

        for state in ["working", "blocked", nil] {
            var pending = helper
            pending.status = state.map { .init(state: $0) }
            store.herdrLive(.helpers(list([pending])), botID: bot.id)
            #expect(store.hasActiveCodingAgent(bot) && store.isWorking(bot) && !store.isAnswering(bot))
        }

        var answered = helper
        answered.answered = true
        store.herdrLive(.helpers(list([answered])), botID: bot.id)
        #expect(!store.hasActiveCodingAgent(bot) && !store.isWorking(bot))

        let finished = HerdrClient.Helper(address: helper.address, createdMs: helper.createdMs, name: helper.name, state: "finished", answered: false)
        store.herdrLive(.helpers(list([answered, finished])), botID: bot.id)
        #expect(!store.hasActiveCodingAgent(bot) && !store.isWorking(bot))
    }

    @Test func workspaceDiscoversUnselectedHelpersAndTracksTheBotsOwnSession() async throws {
        let store = makeStore()
        let open = Bot(name: "Open", backend: .herdr), background = Bot(name: "Background", backend: .herdr)
        let ownAgent = Bot(name: "Independent", backend: .herdr), remote = Bot(name: "Remote", backend: .herdr)
        let sample = Bot(name: "Sample", backend: .mock)
        store.bots = [open, background, ownAgent, remote, sample]
        let other = HerdrServer(id: "other", name: "Other", kind: .address, address: "http://127.0.0.1:1")
        store.saveHerdrServer(other, token: nil)
        store.setHerdrServer(other.id, for: remote)
        store.setHerdrServer(other.id, for: sample)
        let serverID = store.herdrServer(for: open).id
        #expect(store.herdrHelperWatch() == [serverID: false, other.id: false])
        store.selectedBot = open

        let openName = HerdrBackend.agentName(botName: open.name, botID: open.id)
        let backgroundName = HerdrBackend.agentName(botName: background.name, botID: background.id)
        let ownName = HerdrBackend.agentName(botName: ownAgent.name, botID: ownAgent.id)
        let http = MockHTTPProtocol.serve { request in
            switch request.url?.path {
            case "/api/workspace":
                let reads = MockHTTPProtocol.recorded(request.url?.host ?? "").filter { $0.url?.path == "/api/workspace" }.count
                var agents: [[String: Any]] = [["address": "open", "created_ms": 3, "name": openName, "state": "live"]]
                if reads == 1 {
                    agents += [
                        ["address": "parent", "created_ms": 1, "name": backgroundName, "state": "live"],
                        ["address": "child", "created_ms": 2, "name": "helper", "state": "live", "parent": ["address": "parent", "created_ms": 1]],
                        ["address": "own", "created_ms": 4, "name": ownName, "state": "live", "status": ["state": "working"]]
                    ]
                }
                return (200, ["core": "fixture", "templates": [], "agents": agents])
            case "/api/agents/parent/1/helpers":
                return (200, ["core": "fixture", "parent": ["address": "parent", "created_ms": 1], "helpers": [
                    ["address": "child", "created_ms": 2, "name": "Build Scout", "state": "live", "status": ["state": "working"]]
                ]])
            default: return (404, [:])
            }
        }
        store.saveHerdrServer(HerdrServer(id: serverID, name: "Test", kind: .address, address: "http://\(http.host)"), token: "fixture")
        store.herdrClientSetup = { $0.session = http.session }
        await store.refreshHerdrHelpers(on: serverID)

        #expect(store.selectedBot === open)
        #expect(store.herdrHelpers[background.id]?.helpers.map(\.ref) == [helper.ref])
        #expect(store.hasActiveCodingAgent(background) && store.isWorking(background))
        #expect(store.herdrHelperOverview.rows.first?.bot === background)
        #expect(store.herdrHelperOverview.withoutDetachedActivity.map(\.id) == [serverID])
        #expect(!store.herdrHelperOverview.unavailable.contains { $0.id == serverID }, "an older bridge still supplies native helpers")
        #expect(store.herdrTerminalSession(for: background) == parent)
        let own = try #require(store.herdrTerminalSession(for: ownAgent))
        #expect(own == HerdrClient.AgentRef(address: "own", createdMs: 4))
        #expect(store.hasActiveCodingAgent(ownAgent) && store.isWorking(ownAgent))
        #expect(!store.hasActiveCodingAgent(open) && store.herdrTerminalSession(for: open) != nil)
        #expect(store.herdrHelperWatch() == [serverID: true, other.id: false])

        var cached = HerdrAgentReading(templates: [], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: [])
        cached.session = own
        store.herdrAgentReadings[ownAgent.id] = cached
        store.herdrLive(.following(true), botID: background.id)
        store.herdrLive(.helpers(list([helper])), botID: background.id)
        await store.refreshHerdrHelpers(on: serverID)
        #expect(store.herdrHelpers[background.id] == list([helper]), "workspace polling preserves the active stream's list")
        store.herdrLive(.following(false), botID: background.id)
        await store.refreshHerdrHelpers(on: serverID)
        #expect(store.herdrHelpers[background.id] == nil && !store.isWorking(background))
        #expect(store.herdrTerminalSession(for: ownAgent) == nil && !store.isWorking(ownAgent))
        #expect(store.herdrHelperWatch() == [serverID: false, other.id: false])
        #expect(MockHTTPProtocol.recorded(http.host).compactMap { $0.url?.path } == ["/api/workspace", "/api/agents/parent/1/helpers", "/api/workspace", "/api/workspace"])

        store.bots = [sample]
        #expect(store.herdrHelperWatch().isEmpty)
    }

    @Test func sidebarWatchesConnectedSSHAndDisconnectedSSHUsesChatActivity() {
        let store = makeStore()
        let local = Bot(name: "Local", backend: .herdr), remote = Bot(name: "Remote", backend: .herdr)
        store.bots = [local, remote]
        let ssh = HerdrServer(id: "ssh", name: "SSH", kind: .ssh, address: HerdrServer.loopback(port: 9_000), sshHost: "remote.example")
        store.saveHerdrServer(ssh, token: nil)
        store.setHerdrServer(ssh.id, for: remote)
        let localID = store.herdrServer(for: local).id
        #expect(store.herdrHelperWatch() == [localID: false])
        #expect(store.herdrHelperWatch(servers: store.herdrServers, sshIsOpen: { _ in true }) == [localID: false, ssh.id: false])
        store.selectedBot = local
        #expect(store.herdrHelperWatch(servers: store.herdrServers, sshIsOpen: { $0 == ssh.id }) == [localID: false, ssh.id: false])
        store.showInfo = false
        #expect(store.herdrHelperWatch(servers: store.herdrServers, sshIsOpen: { _ in true }) == [localID: false, ssh.id: false])
        store.showInfo = true

        store.selectedBot = remote
        #expect(store.herdrHelperWatch() == [localID: false, ssh.id: false])
        store.selectedBot = local
        store.selectedGroup = GroupChat(name: "Team", memberIDs: [local.id, remote.id])
        #expect(store.herdrHelperWatch() == [localID: false, ssh.id: false])
        store.selectedGroup = nil

        let turn = store.beginTurn(in: remote, bot: remote, assistant: nil)
        #expect(store.herdrHelperWatch() == [localID: false, ssh.id: true])
        store.endTurn(turn.token)
        store.herdrLive(.helpers(list([helper])), botID: remote.id)
        #expect(store.herdrHelperWatch() == [localID: false, ssh.id: true])
        store.herdrLive(.helpers(list([])), botID: remote.id)
        #expect(store.herdrHelperWatch() == [localID: false])
    }

    @Test func overviewAttributesMatchingHelperIDsToTheirParentsAndTracksFollowUps() throws {
        let store = makeStore()
        let first = Bot(name: "Build", backend: .herdr), second = Bot(name: "Review", backend: .herdr)
        let remote = HerdrServer(id: "remote", name: "Review host", kind: .address, address: "http://review.test")
        store.bots = [first, second]
        store.saveHerdrServer(remote, token: "fixture")
        store.setHerdrServer(remote.id, for: second)
        store.open(first)
        #expect(!store.herdrHelperOverview.confirmedEmpty)
        store.herdrLive(.helpers(list([helper])), botID: first.id)
        store.herdrLive(.helpers(list([helper])), botID: second.id)
        let rows = store.herdrHelperOverview.rows
        #expect(rows.map(\.bot.id) == [first.id, second.id])
        #expect(Set(rows.map(\.id)).count == 2)

        var changed = helper
        changed.status = .init(state: "working")
        changed.currentTask = "Inspect the second build.\nInclude all warnings."
        store.herdrLive(.helpers(list([changed])), botID: second.id)
        let updated = try #require(store.herdrHelperOverview.rows.last)
        #expect(updated.id == rows[1].id && updated.helper.currentTask == changed.currentTask)
        #expect(updated.helper.taskLine == "Inspect the second build. Include all warnings.")
        #expect(store.selectedBot === first)
        store.open(updated.helper, of: updated.bot)
        #expect(store.selectedBot === second && store.openHerdrHelper == updated.id)

        for state in ["blocked", "error", "done"] {
            changed.status = .init(state: state)
            store.herdrLive(.helpers(list([changed])), botID: second.id)
            #expect(store.herdrHelperOverview.rows.map(\.id) == [rows[0].id])
        }
        changed.answered = true
        store.herdrLive(.helpers(list([changed])), botID: second.id)
        #expect(store.herdrHelperOverview.rows.map(\.id) == [rows[0].id])
        #expect(store.herdrHelpers[second.id]?.helpers == [changed])
        let gone = HerdrClient.Helper(address: "ended", createdMs: 3, name: "Old helper", state: "gone")
        store.herdrLive(.helpers(list([gone])), botID: first.id)
        #expect(store.herdrHelperOverview.rows.isEmpty)
        #expect(!store.herdrHelperOverview.confirmedEmpty, "empty streams cannot confirm the workspace roster or detached activity")
    }

    @Test func overviewRoutesWorkingNativeThreadsAndClearsThemWhenFinished() {
        let store = makeStore()
        let bot = Bot(name: "Patch", backend: .herdr)
        store.bots = [bot]
        let server = store.herdrServer(for: bot)
        store.helperRosters[server.id] = .available(unattributed: 0)
        store.herdrCodejobReads[server.id] = .init(server: server, hosts: [], observed: .now)
        func listing(_ state: String) -> HerdrClient.Helpers {
            var result = list([])
            for runtime in [HerdrClient.ChildRuntime.claude, .opencode, .codex, .gemini] {
                let thread = HerdrClient.NativeThread(id: "shared", parent: "root", runtime: runtime, name: "Scout",
                                                      model: nil, createdMs: 1, state: state, task: "Inspect", reply: "")
                switch runtime {
                case .claude: result.claudeThreads = [thread]
                case .opencode: result.opencodeThreads = [thread]
                case .gemini: result.geminiThreads = [thread]
                case .codex: result.codexThreads = [thread]
                }
            }
            return result
        }
        store.herdrLive(.helpers(listing("working")), botID: bot.id)
        let rows = store.herdrHelperOverview.nativeRows
        #expect(Set(rows.map(\.id)).count == 4)
        #expect(rows.allSatisfy { $0.bot.id == bot.id && $0.server == server && $0.target.id.child?.owner == parent })
        #expect(store.hasActiveCodingAgent(bot) && !store.herdrHelperOverview.confirmedEmpty)
        let old = HerdrHelperParent(botID: bot.id, archive: .init(core: "archive", session: parent))
        store.herdrHelpers[old] = listing("working")
        store.herdrHelperReads[old] = .polled
        store.herdrLive(.helpers(listing("answered")), botID: bot.id)
        #expect(store.herdrHelperOverview.nativeRows.isEmpty && store.herdrHelperOverview.confirmedEmpty)
        #expect(!store.hasActiveCodingAgent(bot))
    }

    @Test func overviewDistinguishesOlderWorkspacesFromIncompleteActivityReads() async {
        let api = LockedValue(2), malformed = LockedValue(false)
        let http = MockHTTPProtocol.serve { _ in
            var body: [String: Any] = ["core": "c", "agents": [], "templates": [],
                                        "bridge": ["version": api.current == 2 ? "0.2.12" : "0.2.13", "api": api.current]]
            if malformed.current { body["codejob_activity"] = "bad feed" }
            return (200, body)
        }
        let store = makeStore()
        let owner = Bot(name: "Owner", backend: .herdr)
        store.bots = [owner]
        store.open(owner)
        let server = HerdrServer(id: HerdrServer.defaultID, name: "Fixture", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: "fixture")
        store.herdrClientSetup = { $0.session = http.session }
        #expect(store.herdrHelperWatch() == [server.id: false])
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.withoutDetachedActivity == [server])
        #expect(store.herdrHelperOverview.unavailable.isEmpty && store.herdrHelperOverview.confirmedEmpty)
        _ = malformed.swap(true)
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.unavailable == [server])
        _ = api.swap(3)
        _ = malformed.swap(false)
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.unavailable == [server] && !store.herdrHelperOverview.confirmedEmpty)
    }

    @Test func overviewRequiresSuccessfulReadsBeforeReportingNoActiveHelpers() async throws {
        let store = makeStore()
        let open = Bot(name: "Open", backend: .herdr), remote = Bot(name: "Remote", backend: .herdr)
        store.bots = [open, remote]
        store.open(open)
        let local = store.herdrServer(for: open)
        store.herdrCodejobReads[local.id] = .init(server: local, hosts: [], observed: .now)
        store.herdrLive(.helpers(list([helper])), botID: open.id)
        store.helperRosters[store.herdrServer(for: open).id] = .available(unattributed: 0)
        let group = GroupChat(name: "Review team", memberIDs: [remote.id])
        store.groups = [group]
        let legacySession = "previous-install-" + GroupRouting.sessionID(group: group.id, bot: remote.id)
        group.sessions[remote.id.uuidString.lowercased()] = legacySession
        let groupName = try #require(HerdrBackend.groupRuntimeName(sessionID: legacySession, botID: remote.id))
        #expect(legacySession != store.turnSessionID(in: group, bot: remote))
        let remoteName = HerdrBackend.agentName(botName: remote.name, botID: remote.id)
        let http = MockHTTPProtocol.serve { request in
            if request.url?.path == "/api/workspace" {
                let attempts = MockHTTPProtocol.recorded(request.url?.host ?? "").filter { $0.url?.path == "/api/workspace" }.count
                switch attempts {
                case 1:
                    return (200, ["core": "r", "codejob_activity": [], "templates": [], "agents": [
                        ["address": "p", "created_ms": 1, "name": remoteName, "state": "live"],
                        ["address": "child", "created_ms": 2, "name": "child", "state": "live", "parent": ["address": "p", "created_ms": 1]],
                        ["address": "g", "created_ms": 3, "name": groupName, "state": "live"],
                        ["address": "team", "created_ms": 4, "name": "team", "state": "live", "parent": ["address": "g", "created_ms": 3]]
                    ]])
                case 2: return (0, URLError(.cannotConnectToHost))
                case 3: return (401, [:])
                default: return (200, ["core": "r", "codejob_activity": [], "templates": [], "agents": []])
                }
            }
            if request.url?.path == "/api/agents/p/1/helpers" {
                return (200, ["core": "r", "parent": ["address": "p", "created_ms": 1], "helpers": [
                    ["address": "child", "created_ms": 2, "name": "Reader", "state": "live",
                     "status": ["state": "idle"], "task": "Original", "current_task": "Latest\nassignment"]
                ]])
            }
            if request.url?.path == "/api/agents/g/3/helpers" { return (403, [:]) }
            return (404, [:])
        }
        let server = HerdrServer(id: "remote", name: "Remote host", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: nil)
        store.setHerdrServer(server.id, for: remote)
        store.herdrClientSetup = { $0.session = http.session }
        #expect(store.herdrHelperOverview.checking == [server])
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.unavailable == [server] && MockHTTPProtocol.recorded(http.host).isEmpty)

        store.setHerdrToken("fixture", for: server)
        await store.refreshHerdrHelpers(on: server.id)
        let latest = try #require(store.herdrHelperOverview.rows.first { $0.bot === remote })
        #expect(latest.helper.currentTask == "Latest\nassignment" && latest.helper.statusLine == "Starting")
        #expect(store.herdrHelperOverview.unavailable == [server], "the direct session succeeded but the group helper list was refused")
        store.herdrLive(.helpers(list([helper])), botID: remote.id, groupRuntime: groupName)
        let team = try #require(store.herdrHelperOverview.rows.first { $0.id.groupRuntime == groupName })
        #expect(team.groupName == group.name && store.herdrHelpers[team.id.parent]?.helpers == [helper])
        #expect(store.selectedBot === open && store.openHerdrHelper == nil)
        #expect(store.herdrHelpers[remote.id]?.helpers == [latest.helper])
        #expect(store.herdrHelperOverview.unavailable.isEmpty)
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelpers[remote.id] != nil, "the per-bot cache survives a dropped read")
        #expect(store.herdrHelperOverview.rows.map(\.bot.id) == [open.id, remote.id, remote.id])
        #expect(store.herdrHelperOverview.unavailable == [server])
        store.herdrLive(.helpers(list([])), botID: open.id)
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.rows.count == 2 && !store.herdrHelperOverview.confirmedEmpty)
        #expect(store.herdrHelperOverview.unavailable == [server])
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.confirmedEmpty && store.herdrHelperOverview.unavailable.isEmpty)
        store.herdrLive(.following(true), botID: remote.id)
        store.herdrLive(.helpers(nil), botID: remote.id)
        #expect(!store.herdrHelperOverview.confirmedEmpty && store.herdrHelperOverview.unavailable == [server])
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.confirmedEmpty, "a stream without a listing falls back to the server watch")
        let requests = MockHTTPProtocol.recorded(http.host)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.compactMap { $0.url?.path } == ["/api/workspace", "/api/agents/p/1/helpers", "/api/agents/g/3/helpers",
                                                       "/api/workspace", "/api/workspace", "/api/workspace", "/api/workspace"])
    }

    @Test func failedRosterReadsPreserveStreamOwnershipAndExpireOnlyPolledRows() async throws {
        let store = makeStore()
        let streaming = Bot(name: "Streaming", backend: .herdr), sibling = Bot(name: "Polled", backend: .herdr)
        store.bots = [streaming, sibling]
        let http = MockHTTPProtocol.serve { _ in (503, [:]) }
        let server = HerdrServer(id: store.herdrServers[0].id, name: "Fixture", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: "fixture")
        store.herdrClientSetup = { $0.session = http.session }
        store.open(streaming)
        store.herdrLive(.following(true), botID: streaming.id)
        for bot in store.bots { store.herdrLive(.helpers(list([helper])), botID: bot.id) }
        for attempt in 1...AppStore.herdrHelperFailureLimit {
            await store.refreshHerdrHelpers(on: server.id)
            #expect(store.herdrHelperReads[streaming.id] == .streamed)
            #expect(store.herdrHelpers[streaming.id] == list([helper]))
            #expect((store.herdrHelpers[sibling.id] != nil) == (attempt < AppStore.herdrHelperFailureLimit))
        }
        store.herdrLive(.helpers(nil), botID: streaming.id)
        #expect(store.herdrHelpers[streaming.id] == list([helper]))
        store.herdrLive(.helpers(list([])), botID: streaming.id)
        #expect(store.herdrHelpers[streaming.id] == nil)
    }

    @Test func sidebarTreeRespectsCoreGroupLaunchAndCollapseEvenWithACycle() {
        let store = makeStore()
        let root = HerdrHelperParent(botID: UUID(), groupRuntime: "team")
        let owner = HerdrClient.AgentRef(address: "parent", createdMs: 2)
        let child = HerdrClient.Helper(address: "a", createdMs: 4, name: "Child", state: "live")
        let nested = HerdrClient.Helper(address: "a", createdMs: 7, name: "Grandchild", state: "live")
        store.herdrHelpers[root] = .init(core: "one", parent: owner, helpers: [child])
        let branch = root.children(of: child.ref, core: "one")
        store.herdrHelpers[branch] = .init(core: "one", parent: child.ref, helpers: [nested])
        store.herdrHelpers[root.children(of: nested.ref, core: "one")] = .init(core: "one", parent: nested.ref, helpers: [child])
        let rows = store.sidebarSessions(under: root)
        #expect(rows.map(\.depth) == [0, 1])
        #expect(rows.map(\.id) == [root.selection(for: child), branch.selection(for: nested)])
        #expect(store.delegatingSession(for: rows[1].id)?.id == root.selection(for: child))
        #expect(store.sidebarSessions(under: root, isFolded: { $0 == rows[0].branch }).count == 1)
        store.herdrHelpers[root] = .init(core: "other", parent: owner, helpers: [child])
        #expect(store.sidebarSessions(under: root).map(\.id) == [root.selection(for: child)])
        #expect(store.delegatingSession(for: rows[1].id) == nil)
        let direct = HerdrHelperParent(botID: root.botID)
        store.herdrHelpers[direct] = .init(core: "one", parent: owner, helpers: [child])
        #expect(store.sidebarSessions(under: direct).count == 1)
    }

    @Test func workspaceHelperFoldSurvivesReloadAndDistinguishesCoreGroupAndLaunch() throws {
        let store = makeStore(), bot = Bot(name: "Owner", backend: .herdr)
        let root = HerdrHelperParent(botID: bot.id)
        let owner = HerdrClient.AgentRef(address: "main", createdMs: 1)
        let helper = HerdrClient.Helper(address: "term", createdMs: 2, name: "Review", state: "live")
        let sub = HerdrClient.Helper(address: "item", createdMs: 3, name: "Citations", state: "live")
        func populate(_ app: AppStore, _ parent: HerdrHelperParent, _ core: String, _ launch: HerdrClient.AgentRef) {
            app.herdrHelpers[parent] = .init(core: core, parent: launch, helpers: [helper])
            app.herdrHelpers[parent.children(of: helper.ref, core: core)] = .init(core: core, parent: helper.ref, helpers: [sub])
        }
        populate(store, root, "one", owner)
        let row = try #require(store.visibleHelperSessions(under: root, for: bot).first)
        store.setHelperBranchFolded(true, branch: row.branch, for: bot)
        let reopened = AppStore(storeURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                                autoStart: false, keyStore: InMemoryKeyStore(), defaults: store.defaults)
        populate(reopened, root, "one", owner)
        #expect(reopened.visibleHelperSessions(under: root, for: bot).map(\.folded) == [true])
        let group = HerdrHelperParent(botID: bot.id, groupRuntime: "release")
        populate(reopened, group, "one", owner)
        #expect(reopened.visibleHelperSessions(under: group, for: bot).count == 2)
        populate(reopened, root, "two", owner)
        #expect(reopened.visibleHelperSessions(under: root, for: bot).count == 2)
        populate(reopened, root, "one", .init(address: owner.address, createdMs: 4))
        #expect(reopened.visibleHelperSessions(under: root, for: bot).count == 2)
        reopened.setHelperBranchFolded(false, branch: row.branch, for: bot)
        #expect(store.visibleHelperSessions(under: root, for: bot).count == 2)
    }

    @Test func nativeBackFollowsTheProviderTreeWithinItsArchivedWorkspaceSession() throws {
        let store = makeStore()
        let bot = Bot(name: "Patch", backend: .herdr)
        let server = store.herdrServer(for: bot)
        let workspace = HerdrClient.Helper(address: "qa", createdMs: 2, name: "Workspace review", state: "live")
        let root = HerdrHelperParent(botID: bot.id, groupRuntime: "old-team",
                                     archive: .init(core: "old", session: parent))
        let branch = root.children(of: workspace.ref, core: "old")
        let review = HerdrClient.NativeThread(id: "r", parent: "main", runtime: .claude, name: "Review",
                                              model: nil, createdMs: 3, state: "working", task: "", reply: "")
        let child = HerdrClient.NativeThread(id: "c", parent: "r", runtime: .claude, name: "Citations",
                                             model: nil, createdMs: 4, state: "working", task: "", reply: "")
        var other = review
        other.runtime = .codex
        store.herdrHelpers[root] = .init(core: "old", parent: parent, helpers: [workspace])
        store.herdrHelpers[branch] = .init(core: "old", parent: workspace.ref, helpers: [],
                                            codexThreads: [other], claudeThreads: [review, child])
        let selected = HerdrHelperSelection(botID: bot.id, helperID: child.id, groupRuntime: root.groupRuntime,
                                           source: branch.source, archive: root.archive,
                                           native: .init(thread: child, core: "old", owner: workspace.ref, server: server))
        store.open(store.backDestination(for: selected, of: bot), of: bot)
        let first = try #require(store.openHerdrHelper)
        #expect(first.native?.thread == review && first.parent == branch)
        store.open(store.backDestination(for: first, of: bot), of: bot)
        #expect(store.openHerdrHelper == root.selection(for: workspace))
        store.herdrHelpers[branch]?.claudeThreads = [child]
        store.open(store.backDestination(for: selected, of: bot), of: bot)
        #expect(store.openHerdrHelper == root.selection(for: workspace))
        store.herdrHelpers[root] = .init(core: "restarted", parent: parent, helpers: [workspace])
        store.herdrHelpers[branch] = nil
        store.open(store.backDestination(for: selected, of: bot), of: bot)
        #expect(store.openHerdrHelper == nil && store.selectedBot?.id == bot.id)
        #expect(store.composerFocus == bot.id)
    }

    @Test func openingSessionRevealsOnlyItsSectionAndAncestors() throws {
        let store = makeStore(), bot = Bot(name: "Patch", backend: .herdr)
        store.bots = [bot]
        #expect(store.createSidebarSection(named: "Release", adding: bot.id))
        let section = try #require(store.sidebar.sections.first?.id)
        let root = HerdrHelperParent(botID: bot.id)
        let branch = root.children(of: helper.ref, core: "core")
        let review = HerdrClient.NativeThread(id: "review", parent: "root", name: "Review", model: nil,
                                              createdMs: 3, state: "working", task: "", reply: "")
        let child = HerdrClient.NativeThread(id: "item", parent: "review", name: "Item", model: nil,
                                             createdMs: 4, state: "working", task: "", reply: "")
        var otherReview = review, otherChild = child
        otherReview.runtime = .claude; otherChild.runtime = .claude
        store.herdrHelpers[root] = .init(core: "core", parent: parent, helpers: [helper])
        store.herdrHelpers[branch] = .init(core: "core", parent: helper.ref, helpers: [],
                                            codexThreads: [review, child], claudeThreads: [otherReview, otherChild])
        let rows = store.sessionRows(under: root, for: bot)
        let target = try #require(rows.first { $0.selection.native?.thread == child }).selection
        for row in rows where row.selection.helperID == review.id { store.setNativeSessionFolded(true, target: row.id, for: bot) }
        let ancestor = try #require(store.sidebarSessions(under: root).first)
        store.setHelperBranchFolded(true, branch: ancestor.branch, for: bot)
        store.setSessionsExpanded(false, for: bot)
        store.setSidebarSectionCollapsed(section, true)
        store.open(bot, helper: target)
        #expect(store.sessionsExpanded(for: bot) && store.sidebar.section(section)?.collapsed == false)
        #expect(store.sessionRows(under: root, for: bot).map(\.selection.native?.thread) == [nil, review, child, otherReview])
    }

    @Test func sidebarFoldsSurviveReopeningAndKeepOtherLaunchesAndProvidersVisible() throws {
        let store = makeStore()
        let bot = Bot(name: "Patch", backend: .herdr)
        let review = HerdrClient.NativeThread(id: "review", parent: "main", name: "Review", model: nil,
                                              createdMs: 3, state: "working", task: "", reply: "")
        let child = HerdrClient.NativeThread(id: "item", parent: review.id, name: "Item", model: nil,
                                             createdMs: 4, state: "working", task: "", reply: "")
        var otherReview = review, otherChild = child
        otherReview.runtime = .claude
        otherChild.runtime = .claude
        let list = HerdrClient.Helpers(core: "core", parent: parent, helpers: [],
                                       codexThreads: [child, review], claudeThreads: [otherReview, otherChild])
        let row = try #require(store.nativeSidebarRows(list, for: bot).first)
        #expect(row.thread == review && row.hasChildren)
        store.setNativeSessionFolded(true, target: row.id, for: bot)
        let reopened = AppStore(storeURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                                autoStart: false, keyStore: MemoryKeyStore(), defaults: store.defaults)
        let rows = reopened.nativeSidebarRows(list, for: bot)
        #expect(rows.map(\.thread) == [review, otherReview, otherChild])
        #expect(rows.map(\.depth) == [0, 0, 1])
        #expect(rows[0].folded && !rows[1].folded)
        let newLaunch = HerdrClient.Helpers(core: "core", parent: .init(address: parent.address, createdMs: 9),
                                            helpers: [], codexThreads: [review, child])
        #expect(reopened.nativeSidebarRows(newLaunch, for: bot).count == 2)
        let sibling = Bot(name: "Other", backend: .herdr)
        #expect(reopened.nativeSidebarRows(list, for: sibling).count == 4)
        reopened.setNativeSessionFolded(false, target: row.id, for: bot)
        #expect(store.nativeSidebarRows(list, for: bot).count == 4)
    }

    @Test func unmatchedRosterChildrenPreventAnEmptyOverview() async throws {
        let store = makeStore()
        let bot = Bot(name: "Direct", backend: .herdr)
        store.bots = [bot]
        store.open(bot)
        let http = MockHTTPProtocol.serve { _ in
            (200, ["core": "r", "templates": [], "agents": [
                ["address": "child", "created_ms": 3, "name": "Unassigned", "state": "live",
                 "parent": ["address": "departed", "created_ms": 1]]
            ]])
        }
        let server = HerdrServer(id: store.herdrServers[0].id, name: "Fixture", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: "fixture")
        store.herdrClientSetup = { $0.session = http.session }
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.unattributed.first?.count == 1)
        #expect(!store.herdrHelperOverview.confirmedEmpty)
    }

    @Test func pinnedMainBotShowsTerminalUnreadAndAttentionTogether() async throws {
        let store = makeStore()
        let bot = Bot(name: "Pinned", backend: .herdr, avatarName: .faceMint, unreadCount: 1)
        bot.messages = [ChatMessage(role: .assistant, content: "Partial reply", turnState: .incomplete)]
        store.bots = [bot]
        store.herdrLive(.helpers(list([helper])), botID: bot.id)

        let size = NSSize(width: 240, height: 120)
        func render() async throws -> CGImage {
            let view = SidebarPinnedStrip(chats: [.bot(bot)], askNewSection: { _ in }, requestDelete: { _ in })
                .environmentObject(store).tint(Color(nsColor: .magenta))
                .frame(width: size.width, height: size.height, alignment: .top).background(Color.white)
            let data = try #require(await SnapshotRenderer.png(view, size: size, scale: 1))
            return try #require(NSBitmapImageRep(data: data)?.cgImage)
        }

        let statusOnly = try await render()
        store.setCanManageBots(bot, true)
        let together = try await render()
        store.herdrLive(.helpers(list([])), botID: bot.id)
        bot.unreadCount = 0
        bot.messages.removeAll()
        let starOnly = try await render()

        // A single 56-point avatar is centered at x=120, with its top at y=20.
        func pixels(_ image: CGImage, in region: CGRect) throws -> [NSColor] {
            let crop = try #require(image.cropping(to: region))
            let bitmap = NSBitmapImageRep(cgImage: crop)
            return (0..<bitmap.pixelsHigh).flatMap { y in
                (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y) }
            }
        }
        let star = CGRect(x: 92, y: 20, width: 24, height: 24)
        let terminal = CGRect(x: 90, y: 56, width: 22, height: 23)
        let unread = CGRect(x: 138, y: 19, width: 12, height: 12)
        let attention = CGRect(x: 136, y: 64, width: 16, height: 16)
        let starPixels = try pixels(together, in: star)
        #expect(try starPixels == pixels(starOnly, in: star))
        #expect(try starPixels != pixels(statusOnly, in: star))
        for region in [terminal, unread, attention] {
            let statusPixels = try pixels(together, in: region)
            #expect(try statusPixels == pixels(statusOnly, in: region))
            #expect(try statusPixels != pixels(starOnly, in: region))
        }
        // Check the white terminal symbol inside its dark badge, excluding the border.
        #expect(try lightPixels(in: CGRect(x: 94, y: 61, width: 14, height: 12), of: together) > 4)
    }

    @Test func chatShowsOnlyLiveHelpersAndKeepsTheBotsTerminalSeparate() async throws {
        let store = makeStore()
        let bot = Bot(name: "Bot fixture", backend: .herdr)
        bot.messages = [ChatMessage(role: .assistant, content: "The build is ready.")]
        store.bots = [bot]
        store.selectedBot = bot
        let finished = HerdrClient.Helper(address: "ended", createdMs: 3, name: "Retired Scout", state: "finished")
        store.herdrHelpers[bot.id] = list([helper, finished])

        let size = NSSize(width: 760, height: 500)
        let view = ChatView(bot: bot).environmentObject(store).defaultAppStorage(store.defaults)
        func render() async throws -> CGImage {
            let data = try #require(await SnapshotRenderer.png(view, size: size, scale: 1))
            return try #require(NSBitmapImageRep(data: data)?.cgImage)
        }

        let live = try await render()

        store.herdrHelpers[bot.id] = list([finished])
        let ended = try await render()

        var reading = HerdrAgentReading(templates: [], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: [])
        reading.session = parent
        store.herdrAgentReadings[bot.id] = reading
        let own = try await render()

        // The light text of the card and both actions stands out against the dark chat in each region.
        // The transcript and composer sit outside these crops.
        let card = CGRect(x: 30, y: 303, width: 240, height: 108)
        let helperTerminal = CGRect(x: 555, y: 303, width: 107, height: 108)
        let details = CGRect(x: 664, y: 303, width: 66, height: 108)
        func headerHasTerminal(_ image: CGImage) async throws -> Bool {
            let header = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: size.width, height: 54)))
            return try await recognizedLines(in: header).contains { $0.contains("Terminal") }
        }
        for region in [card, helperTerminal, details] {
            #expect(try lightPixels(in: region, of: live) > 30)
            #expect(try lightPixels(in: region, of: ended) == 0)
            #expect(try lightPixels(in: region, of: own) == 0)
        }
        #expect(try await !headerHasTerminal(live))
        #expect(try await !headerHasTerminal(ended))
        #expect(try await headerHasTerminal(own))
    }

    // Normal GET responses captured by HerdrWorkspace/tests/codejob_activity.py.
    @Test(detachedRosterFixture) func detachedRecordIngestion() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        if suppliedCodejobRosters == nil {
            let ran = try await codejobFixture(["--write-rosters", output.path])
            try #require(ran.status == 0, "Fixture failed: \(ran.output)")
        }
        let source = try Data(contentsOf: suppliedCodejobRosters ?? output)
        let values = try #require(JSONSerialization.jsonObject(with: source) as? [[String: Any]])
        let responses = try values.map { try JSONSerialization.data(withJSONObject: $0) }
        try #require(responses.count == 8)
        let http = MockHTTPProtocol.serve { request in
            guard request.httpMethod == "GET", request.url?.path == "/api/workspace",
                  request.url?.query == "codejobs=true" else { return (404, [:]) }
            let index = MockHTTPProtocol.recorded(request.url?.host ?? "").count - 1
            return responses.indices.contains(index) ? (200, responses[index]) : (503, [:])
        }
        let store = makeStore()
        let owner = Bot(id: try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")), name: "Swarmhub", backend: .herdr)
        let other = Bot(id: try #require(UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")), name: owner.name, backend: .herdr)
        store.bots = [other, owner]
        store.open(other)
        let server = HerdrServer(id: HerdrServer.defaultID, name: "Fixture", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: "fixture")
        store.herdrClientSetup = { $0.session = http.session }

        var workingID: HerdrCodejobRow.ID?
        for index in responses.indices {
            await store.refreshHerdrHelpers(on: server.id)
            let overview = store.herdrHelperOverview
            #expect(overview.rows.isEmpty && store.herdrTerminalSession(for: owner) == nil)
            #expect(!store.hasActiveCodingAgent(other) && store.selectedBot === other)
            #expect(store.hasActiveCodingAgent(owner) == [1, 6].contains(index))
            #expect(store.isWorking(owner) == [1, 6].contains(index))
            switch index {
            case 0, 1, 2, 6:
                let row = try #require(overview.codejobs.first)
                #expect(overview.codejobs.count == 1 && row.bot === owner && row.id.host == "fixture-host")
                if let workingID { #expect(row.id == workingID) } else { workingID = row.id }
                if index == 0 { #expect([.wrapper, .queued].contains(row.job.state)) }
                if index == 1 || index == 6 { #expect(row.job.description == "Codex working") }
                if index == 2 { #expect(row.job.state == .unknown) }
                if index == 1 {
                    let section = HerdrActiveHelpersSection().environmentObject(store).padding().background(AppColor.chat)
                    let png = try #require(await SnapshotRenderer.png(section, size: NSSize(width: 420, height: 160), scale: 2))
                    let image = try #require(NSBitmapImageRep(data: png)?.cgImage)
                    let words = try await recognizedLines(in: image).joined(separator: " ")
                    #expect(words.localizedCaseInsensitiveContains("Codex working"))
                }
                if index == 6, let read = store.herdrCodejobReads[server.id] {
                    store.herdrCodejobReads[server.id] = .init(server: server, hosts: read.hosts, observed: .now - .seconds(26))
                    #expect(!store.hasActiveCodingAgent(owner) && store.herdrHelperOverview.codejobs.isEmpty)
                    #expect(!store.herdrHelperOverview.confirmedEmpty)
                }
            case 3...5:
                #expect(overview.codejobs.isEmpty && !overview.confirmedEmpty && !overview.unavailableCodejobHosts.isEmpty)
            default:
                #expect(overview.confirmedEmpty)
            }
        }
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.unavailable == [server] && !store.herdrHelperOverview.confirmedEmpty)
        #expect(MockHTTPProtocol.recorded(http.host).count == 9)
    }

    private func lightPixels(in region: CGRect, of image: CGImage) throws -> Int {
        let crop = try #require(image.cropping(to: region))
        let bitmap = NSBitmapImageRep(cgImage: crop)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.58 { count += 1 }
            }
        }
        return count
    }

    @Test func helperDisclosuresFollowTheChildrenLeftInTheSidebar() throws {
        let store = makeStore(), bot = Bot(name: "GameDev", backend: .herdr)
        let root = HerdrHelperParent(botID: bot.id)
        let owner = HerdrClient.AgentRef(address: "qa", createdMs: 1)
        let shell = HerdrClient.Helper(address: "worker", createdMs: 2, name: "Build", state: "live")
        let branch = root.children(of: shell.ref, core: "test")
        store.herdrHelpers[root] = .init(core: "test", parent: owner, helpers: [shell])

        func snapshot(_ first: String, _ second: String) -> HerdrClient.Helpers {
            let parent = HerdrClient.NativeThread(id: "review", parent: "root", name: "Review", model: nil,
                                                  createdMs: 3, state: first, task: "", reply: "")
            let leaf = HerdrClient.NativeThread(id: "check", parent: "review", name: "Check", model: nil,
                                                createdMs: 4, state: second, task: "", reply: "")
            return .init(core: "test", parent: shell.ref, helpers: [], codexThreads: [parent, leaf])
        }
        func rows() -> [SidebarSessionItem] {
            store.sessionRows(under: root, for: bot)
        }
        store.setAutoHideFinishedHelpers(true)
        store.herdrHelpers[branch] = snapshot("working", "answered")
        guard case .workspace(let outer) = rows().first, case .native(let review, _, _) = rows().last else {
            Issue.record("Expected a workspace helper with a provider-native child")
            return
        }
        #expect(outer.hasChildren)
        #expect(!review.hasChildren)
        store.setNativeSessionFolded(true, target: review.id, for: bot)
        store.herdrHelpers[branch] = snapshot("answered", "working")
        guard case .native(let folded, _, _) = rows().last else { Issue.record("Missing folded ancestor"); return }
        #expect(folded.hasChildren && folded.folded)
        store.setSessionsExpanded(false, for: bot)
        let collapsed = store.sidebarSessionGroups(for: bot, roots: [root]).flatMap(\.rows)
        #expect(collapsed.map(\.selection.helperID) == [outer.id.helperID, "review", "check"])
        #expect(collapsed.filter(\.isWorking).map(\.selection.helperID) == ["check"])
        store.setSessionsExpanded(true, for: bot)
        #expect(rows().last?.selection.helperID == "review")
        store.setNativeSessionFolded(false, target: review.id, for: bot)
        #expect(rows().last?.selection.helperID == "check")

        store.herdrHelpers[branch] = snapshot("answered", "answered")
        guard case .workspace(let single) = rows().first else { Issue.record("Missing working helper"); return }
        #expect(rows().count == 1 && !single.hasChildren)
        store.herdrHelpers[root] = .init(core: "test", parent: owner, helpers: [])
        #expect(store.sidebarSessionGroups(for: bot, roots: [root]).isEmpty)
        store.herdrHelpers[root] = snapshot("answered", "answered")
        #expect(store.sidebarSessionGroups(for: bot, roots: [root]).isEmpty)
        store.setAutoHideFinishedHelpers(false)
        #expect(store.sidebarSessionGroups(for: bot, roots: [root]).first?.rows.count == 2)
    }

    @Test func finishedHelperVisibilitySurvivesRefreshAndKeepsThePathToActiveChildren() throws {
        let store = makeStore(), bot = Bot(name: "GameDev", backend: .herdr)
        let root = HerdrHelperParent(botID: bot.id)
        let owner = HerdrClient.AgentRef(address: "qa", createdMs: 1)
        func thread(_ name: String, parent: String = "root", state: String) -> HerdrClient.NativeThread {
            .init(id: name, parent: parent, name: name, model: nil, createdMs: 2, state: state, task: "", reply: "")
        }
        let old = thread("Raman", state: "answered")
        let parent = thread("Review", state: "finished")
        let child = thread("Check", parent: parent.id, state: "working")
        let shell = HerdrClient.Helper(address: "shell", createdMs: 2, name: "Build", state: "finished")
        let snapshot = HerdrClient.Helpers(core: "test", parent: owner, helpers: [shell], codexThreads: [old, parent, child])
        store.herdrHelpers[root] = snapshot
        func ids(_ store: AppStore) -> [String] {
            store.sessionRows(under: root, for: bot).map(\.selection.helperID)
        }
        let original = ids(store)
        let row = try #require(store.sessionRows(under: root, for: bot).first { $0.selection.helperID == old.id })
        store.removeSidebarHelper(row, for: bot)
        store.herdrHelpers[root] = snapshot
        #expect(ids(store) == original.filter { $0 != old.id })
        store.setAutoHideFinishedHelpers(true)
        #expect(ids(store) == [parent.id, child.id])
        let reopened = AppStore(storeURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                                autoStart: false, keyStore: MemoryKeyStore(), defaults: store.defaults)
        reopened.herdrHelpers[root] = snapshot
        #expect(ids(reopened) == [parent.id, child.id])
        reopened.herdrHelpers[root]?.codexThreads = [old, parent, thread("Check", parent: parent.id, state: "answered")]
        #expect(ids(reopened).isEmpty)
        #expect(reopened.sessionRows(under: root, for: bot, includingFolded: true).count == 4)
        reopened.setAutoHideFinishedHelpers(false)
        #expect(ids(reopened) == original.filter { $0 != old.id })
        reopened.restoreSidebarHelpers()
        #expect(ids(reopened) == original)
    }

    private func makeStore() -> AppStore {
        AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    private func list(_ helpers: [HerdrClient.Helper]) -> HerdrClient.Helpers {
        .init(core: "fixture", parent: parent, helpers: helpers)
    }
}
