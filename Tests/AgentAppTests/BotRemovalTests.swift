import Foundation
import Testing
@testable import AgentApp

/// A server as the app sees it when a bot is removed: its list of agents, and which of them were ended.
private final class RemovalBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [[String: Any]] = [], endedPaths: [String] = [], down = false, reads = 0, hits = 0

    var ended: [String] { lock.withLock { endedPaths } }
    var workspaceReads: Int { lock.withLock { reads } }
    /// Every request, answered or refused.
    var requests: Int { lock.withLock { hits } }
    func goDown(_ value: Bool = true) { lock.withLock { down = value } }

    func run(_ name: String, address: String, created: Int, state: String = "live", parent: [String: Any]? = nil) {
        lock.withLock {
            var agent: [String: Any] = ["address": address, "created_ms": created, "name": name, "state": state, "template": "tpl-one", "status": NSNull(), "first_message": NSNull()]
            if let parent { agent["parent"] = parent }
            agents.append(agent)
        }
    }

    func session() -> (address: String, session: URLSession) {
        let (host, session) = MockHTTPProtocol.serve { [self] in answer($0) }
        return ("http://\(host)", session)
    }

    private func answer(_ request: URLRequest) -> (Int, Any) {
        let path = request.url?.path ?? ""
        return lock.withLock { () -> (Int, Any) in
            hits += 1
            if down { return (503, ["error": "the server is restarting"]) }
            if request.httpMethod == "GET", path == "/api/workspace" {
                reads += 1
                return (200, ["core": "c", "version": "1", "agents": agents, "templates": [Any]()])
            }
            if request.httpMethod == "POST", path.hasSuffix("/end") {
                endedPaths.append(path)
                let parts = path.split(separator: "/")
                agents.removeAll { $0["address"] as? String == String(parts[2]) }
                return (200, [String: Any]())
            }
            return (404, ["error": "no route"])
        }
    }
}

/// Removing a bot ends its agent on its server, and nothing else there.
@MainActor struct BotRemovalTests {
    private func makeStore(_ bridge: RemovalBridge) -> AppStore {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let served = bridge.session()
        store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "t")
        store.herdrClientSetup = { made in made.session = served.session }
        // Removing a bot reaches its server only where the app's own launch work runs.
        store.launchWorkEnabled = true
        return store
    }

    private func name(_ bot: Bot) -> String { HerdrBackend.agentName(botName: bot.name, botID: bot.id) }

    @Test func removingABotEndsItsAgentAndNoOther() async throws {
        let bridge = RemovalBridge(), store = makeStore(bridge)
        let infra = Bot(name: "Infra", backend: .herdr), jarvis = Bot(name: "Jarvis", backend: .herdr)
        store.bots = [jarvis, infra]
        bridge.run(name(jarvis), address: "t1", created: 1)
        bridge.run(name(infra), address: "t2", created: 2)
        // A helper the bot's agent started, an agent of the same name that has finished, and one started outside the app.
        bridge.run("tests", address: "t3", created: 3, parent: ["address": "t2", "created_ms": 2])
        bridge.run(name(infra), address: "t0", created: 0, state: "finished")
        bridge.run("infra", address: "t4", created: 4)

        #expect(store.herdrEnding(for: infra) == HerdrAgentEnding(server: HerdrServer.defaultID, agent: name(infra), bot: "Infra"))
        store.delete(infra)
        try await waitUntil { bridge.ended.count == 1 && store.herdrEndings.isEmpty }
        #expect(bridge.ended == ["/api/agents/t2/2/end"], "only the removed bot's running agent")
        #expect(store.bots.map(\.name) == ["Jarvis"])
        #expect(store.herdrEndings.isEmpty, "nothing is left to end")
    }

    @Test func aBotWhoseAgentIsNotRunningIsSimplyRemoved() async throws {
        let bridge = RemovalBridge(), store = makeStore(bridge)
        let infra = Bot(name: "Infra", backend: .herdr), other = Bot(name: "Other", backend: .herdr)
        store.bots = [infra, other]
        bridge.run(name(other), address: "t1", created: 1)
        store.delete(infra)
        try await waitUntil { bridge.workspaceReads >= 1 && store.herdrEndings.isEmpty }
        #expect(bridge.ended.isEmpty && store.bots.map(\.name) == ["Other"])
    }

    @Test func aServerThatCannotBeReachedIsToleratedAndAskedAgainLater() async throws {
        let bridge = RemovalBridge(), store = makeStore(bridge)
        let infra = Bot(name: "Infra", backend: .herdr)
        store.bots = [infra]
        bridge.run(name(infra), address: "t2", created: 2)
        bridge.goDown()
        store.delete(infra)
        // The bot is gone at once, no error is raised, and its agent stays noted.
        #expect(store.bots.isEmpty && store.errorMessage == nil)
        #expect(store.herdrEndings.map(\.agent) == [name(infra)])
        try await waitUntil { bridge.requests >= 1 }
        await store.settleHerdrEndings()
        #expect(bridge.ended.isEmpty && store.herdrEndings.count == 1 && store.errorMessage == nil)
        // The server is back: the next try (at launch, or when another bot is removed) ends it.
        bridge.goDown(false)
        await store.settleHerdrEndings()
        #expect(bridge.ended == ["/api/agents/t2/2/end"] && store.herdrEndings.isEmpty)
    }

    @Test func aBotWithoutAnAgentOnAServerEndsNothing() {
        let bridge = RemovalBridge(), store = makeStore(bridge)
        let sample = Bot(name: "Sample", backend: .mock), archive = Bot(name: "Old", backend: .herdr)
        archive.archivedMembers = ["A", "B"]
        store.bots = [sample, archive]
        #expect(store.herdrEnding(for: sample) == nil)
        #expect(store.herdrEndingPlace(for: sample) == nil)
        store.delete(sample)
        #expect(store.herdrEndings.isEmpty && bridge.workspaceReads == 0)
    }

    @Test func aStoreWithoutLaunchWorkNeverReachesAServerWhenABotIsRemoved() {
        let bridge = RemovalBridge(), store = makeStore(bridge)
        store.launchWorkEnabled = false
        let infra = Bot(name: "Infra", backend: .herdr)
        store.bots = [infra]
        store.delete(infra)
        #expect(store.bots.isEmpty && store.herdrEndings.isEmpty && bridge.workspaceReads == 0)
    }

    @Test func theConfirmationSaysThatTheAgentIsEnded() {
        let bridge = RemovalBridge(), store = makeStore(bridge)
        let infra = Bot(name: "Infra", backend: .herdr)
        store.bots = [infra]
        #expect(BotRemovalCopy.title("Infra") == "Delete Infra?")
        #expect(store.herdrEndingPlace(for: infra) == "Studio")
        #expect(BotRemovalCopy.message(server: "Studio") == "Its chat is removed from this Mac, and its agent on Studio is ended, with what that agent remembers. This can’t be undone.")
        #expect(BotRemovalCopy.message(server: nil) == "Its chat is removed from this Mac. This can’t be undone.")
    }

    @Test func aBotTheMainBotCreatedIsRemovedTheSameWay() async throws {
        let bridge = RemovalBridge(), store = makeStore(bridge)
        let jarvis = Bot(name: "Jarvis", backend: .herdr), legal = Bot(name: "Legal", backend: .herdr)
        jarvis.canManageBots = true
        store.bots = [jarvis, legal]
        bridge.run(name(legal), address: "t7", created: 7)
        store.removeHerdrBot(legal, createdBy: jarvis)
        try await waitUntil { bridge.ended.count == 1 }
        #expect(bridge.ended == ["/api/agents/t7/7/end"])
    }
}
