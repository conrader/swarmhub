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
