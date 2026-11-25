import AppKit
import SwiftUI
import Testing
@testable import AgentApp

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
        #expect(store.herdrHelperOverview.unavailable.contains { $0.id == serverID }, "an older bridge still supplies native helpers")
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

    @Test func connectedSSHIsWatchedWithItsChatClosedAndDisconnectedSSHUsesChatActivity() {
        let store = makeStore()
        let local = Bot(name: "Local", backend: .herdr), remote = Bot(name: "Remote", backend: .herdr)
        store.bots = [local, remote]
        let ssh = HerdrServer(id: "ssh", name: "SSH", kind: .ssh, address: HerdrServer.loopback(port: 9_000), sshHost: "remote.example")
        store.saveHerdrServer(ssh, token: nil)
        store.setHerdrServer(ssh.id, for: remote)
        let localID = store.herdrServer(for: local).id
        #expect(store.herdrHelperWatch() == [localID: false])
        #expect(store.herdrHelperWatch(servers: store.herdrServers, sshIsOpen: { $0 == ssh.id }) == [localID: false, ssh.id: false])

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
        store.herdrLive(.helpers(nil), botID: remote.id)
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
        changed.status = .init(state: "blocked")
        changed.currentTask = "Inspect the second build.\nInclude all warnings."
        store.herdrLive(.helpers(list([changed])), botID: second.id)
        let updated = try #require(store.herdrHelperOverview.rows.last)
        #expect(updated.id == rows[1].id && updated.helper.currentTask == changed.currentTask)
        #expect(updated.helper.statusLine == "Waiting for an answer in its terminal")
        #expect(store.selectedBot === first)
        store.open(updated.helper, of: updated.bot)
        #expect(store.selectedBot === second && store.openHerdrHelper == updated.id)

        changed.answered = true
        store.herdrLive(.helpers(list([changed])), botID: second.id)
        #expect(store.herdrHelperOverview.rows.map(\.id) == [rows[0].id])
        #expect(store.herdrHelpers[second.id]?.helpers == [changed])
        let gone = HerdrClient.Helper(address: "ended", createdMs: 3, name: "Old helper", state: "gone")
        store.herdrLive(.helpers(list([gone])), botID: first.id)
        #expect(store.herdrHelperOverview.rows.isEmpty)
        #expect(!store.herdrHelperOverview.confirmedEmpty, "native streams cannot confirm detached activity")
    }

    @Test func overviewRequiresSuccessfulReadsBeforeReportingNoActiveHelpers() async throws {
        let store = makeStore()
        let open = Bot(name: "Open", backend: .herdr), remote = Bot(name: "Remote", backend: .herdr)
        store.bots = [open, remote]
        store.open(open)
        let local = store.herdrServer(for: open)
        store.herdrCodejobReads[local.id] = .init(server: local, hosts: [], observed: .now)
        store.herdrLive(.helpers(list([helper])), botID: open.id)
        let group = GroupChat(name: "Review team", memberIDs: [remote.id])
        store.groups = [group]
        let groupName = try #require(HerdrBackend.groupRuntimeName(sessionID: store.turnSessionID(in: group, bot: remote), botID: remote.id))
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
        #expect(latest.helper.currentTask == "Latest\nassignment" && latest.helper.statusLine == "Idle")
        #expect(store.herdrHelperOverview.unavailable == [server], "the direct session succeeded but the group helper list was refused")
        store.herdrLive(.helpers(list([helper])), botID: remote.id, groupRuntime: groupName)
        let team = try #require(store.herdrHelperOverview.rows.first { $0.id.groupRuntime == groupName })
        store.open(team.helper, of: team.bot, groupRuntime: team.id.groupRuntime)
        #expect(store.openHerdrHelper == team.id && store.herdrHelpers[team.id.parent]?.helpers == [helper])
        #expect(store.herdrHelpers[remote.id]?.helpers == [latest.helper])
        #expect(store.herdrHelperOverview.unavailable.isEmpty)
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelpers[remote.id] != nil, "the per-bot cache survives a dropped read")
        #expect(store.herdrHelperOverview.rows.map(\.bot.id) == [open.id])
        #expect(store.herdrHelperOverview.unavailable == [server])
        store.herdrLive(.helpers(list([])), botID: open.id)
        await store.refreshHerdrHelpers(on: server.id)
        #expect(store.herdrHelperOverview.rows.isEmpty && !store.herdrHelperOverview.confirmedEmpty)
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
        let card = CGRect(x: 30, y: 329, width: 240, height: 108)
        let helperTerminal = CGRect(x: 555, y: 329, width: 107, height: 108)
        let details = CGRect(x: 664, y: 329, width: 66, height: 108)
        let headerTerminal = CGRect(x: 610, y: 8, width: 138, height: 39)
        for region in [card, helperTerminal, details] {
            #expect(try lightPixels(in: region, of: live) > 30)
            #expect(try lightPixels(in: region, of: ended) == 0)
            #expect(try lightPixels(in: region, of: own) == 0)
        }
        #expect(try lightPixels(in: headerTerminal, of: live) == 0)
        #expect(try lightPixels(in: headerTerminal, of: ended) == 0)
        #expect(try lightPixels(in: headerTerminal, of: own) > 30)
    }

    // Normal GET responses captured by HerdrWorkspace/tests/codejob_activity.py.
    @Test func detachedRecordIngestion() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let supplied = ProcessInfo.processInfo.environment["SWARMHUB_CODEJOB_TEST_ROSTERS"].map { URL(fileURLWithPath: $0) }
        if supplied == nil {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let fixture = Process()
            fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            fixture.arguments = [root.appendingPathComponent("HerdrWorkspace/tests/codejob_activity.py").path, "--write-rosters", output.path]
            let ran = try await runToEnd(fixture)
            try #require(ran.status == 0, "Fixture failed: \(ran.output)")
        }
        let source = try Data(contentsOf: supplied ?? output)
        let values = try #require(JSONSerialization.jsonObject(with: source) as? [[String: Any]])
        let responses = try values.map { try JSONSerialization.data(withJSONObject: $0) }
        #expect(responses.count == 8)
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
