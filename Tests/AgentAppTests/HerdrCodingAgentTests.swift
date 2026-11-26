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
        #expect(store.herdrHelperWatch() == [serverID: false])
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

    @Test func overviewWatchesConnectedSSHAndDisconnectedSSHUsesChatActivity() {
        let store = makeStore()
        let local = Bot(name: "Local", backend: .herdr), remote = Bot(name: "Remote", backend: .herdr)
        store.bots = [local, remote]
        let ssh = HerdrServer(id: "ssh", name: "SSH", kind: .ssh, address: HerdrServer.loopback(port: 9_000), sshHost: "remote.example")
        store.saveHerdrServer(ssh, token: nil)
        store.setHerdrServer(ssh.id, for: remote)
        let localID = store.herdrServer(for: local).id
        #expect(store.herdrHelperWatch() == [localID: false])
        #expect(store.herdrHelperWatch(servers: store.herdrServers, sshIsOpen: { _ in true }) == [localID: false])
        store.selectedBot = local
        #expect(store.herdrHelperWatch(servers: store.herdrServers, sshIsOpen: { $0 == ssh.id }) == [localID: false, ssh.id: false])
        store.showInfo = false
        #expect(store.herdrHelperWatch(servers: store.herdrServers, sshIsOpen: { _ in true }) == [localID: false])
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

    private func makeStore() -> AppStore {
        AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    private func list(_ helpers: [HerdrClient.Helper]) -> HerdrClient.Helpers {
        .init(core: "fixture", parent: parent, helpers: helpers)
    }
}
