import Foundation
import Testing
@testable import AgentApp

private enum MainChoiceDuringUndo: Sendable {
    case unchanged, source, destination
}

@MainActor @Test func remoteToRemoteCutoverRecoversAfterLostActivationAndUndoesOnce() async throws {
    try await verifyRoutineCutoverUndo(.unchanged)
}

@MainActor @Test(arguments: [MainChoiceDuringUndo.source, .destination])
private func undoResumesRoutinesWhenMainChangesDuringSuspension(_ choice: MainChoiceDuringUndo) async throws {
    try await verifyRoutineCutoverUndo(choice)
}

@MainActor private func verifyRoutineCutoverUndo(_ choice: MainChoiceDuringUndo) async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Moved", backend: .herdr)
    let peer = Bot(name: "New Main", backend: .herdr)
    let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    let botID = bot.id.uuidString
    @Sendable func workspace(_ core: String, _ address: String) -> [String: Any] {
        ["core": core, "templates": [["name": "ai"]], "routine_transfers": true,
         "agents": [["name": name, "address": address, "created_ms": 42, "state": "live", "status": ["state": "idle"]]]]
    }
    @Sendable func routine(id: Int, core: String, address: String, owner: String) -> [String: Any] {
        ["id": id, "core": core, "owner_bot": owner, "agent": name, "target": ["address": address, "created_ms": 42],
         "name": "Review changes", "task": "Summarize changes", "state": "paused", "webhook_ready": false,
         "schedule": ["kind": "webhook", "source": "github", "filters": [["field": "action", "equals": "opened"]], "review": true]]
    }
    @Sendable func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data())) as? [String: Any] ?? [:]
    }
    let restores = AwaitableLog<String>()
    let installs = AwaitableLog<Data>()
    let other = UUID().uuidString
    let origin = MockHTTPProtocol.serve { request in
        let item = routine(id: 7, core: "from", address: "old", owner: botID)
        switch request.url?.path {
        case "/api/workspace": return (200, workspace("from", "old"))
        case "/api/routines": return (200, [item, routine(id: 8, core: "from", address: "peer", owner: other)])
        case "/api/profiles": return (200, [])
        default:
            switch body(request)["action"] as? String {
            case "hold": return (200, ["routine": item])
            case "events": return (200, ["digests": []])
            case "restore": restores.append("restore"); return (200, [:])
            default: return (404, [:])
            }
        }
    }
    let attempts = AwaitableLog<String>()
    let undoRequests = AwaitableLog<(action: String, path: String?, attempt: String?)>()
    let chooseMain: @MainActor @Sendable () -> Void = { [weak store, weak peer] in
        if choice != .unchanged, let store, let peer { store.setCanManageBots(peer, true) }
    }
    let destination = MockHTTPProtocol.serve { request in
        if request.url?.path == "/api/workspace" { return (200, workspace("to", "new")) }
        let payload = body(request)
        guard let action = payload["action"] as? String else { return (404, [:]) }
        switch action {
        case "install":
            if let data = try? JSONSerialization.data(withJSONObject: payload) { installs.append(data) }
            return (200, ["routine": routine(id: 12, core: "to", address: "new", owner: botID)])
        case "activate":
            attempts.append("activate")
            if attempts.all.count == 1 { return (503, [:]) }
            return (200, ["routine": routine(id: 12, core: "to", address: "new", owner: botID)])
        case "events": return (200, ["digests": []])
        case "suspend", "resume", "retire":
            undoRequests.append((action, request.url?.path, payload["attempt"] as? String))
            if action == "suspend" { DispatchQueue.main.sync { chooseMain() } }
            return (200, [:])
        default: return (404, [:])
        }
    }
    let a = HerdrServer(id: "vps-a", name: "First", kind: .address, address: "https://\(origin.host)")
    let b = HerdrServer(id: "vps-b", name: "Second", kind: .address, address: "https://\(destination.host)")
    store.bots = [bot, peer]
    store.saveHerdrServers([a,b])
    store.setHerdrServer(a.id, for: bot)
    store.setHerdrServer(choice == .destination ? b.id : a.id, for: peer)
    store.setCanManageBots(bot, true)
    store.setHerdrToken("fixture", for: a)
    store.setHerdrToken("fixture", for: b)
    store.herdrClientSetup = { $0.session = origin.session }
    let record = try await store.moveHerdrBots([bot.id], from: a, to: b, mapping: .matching, carryHistory: true, stopIdleAgents: false)
    #expect(record.activationPending && record.receipts.count == 1 && record.webhookOwners == [bot.id])
    try await store.recoverRoutineMoveFromSettings(from: a, to: b)
    #expect(!store.routineMovePending(from: a, to: b))
    let writes = MockHTTPProtocol.recorded(destination.host).filter { $0.httpMethod == "POST" }
    #expect(installs.all.count == 1)
    let data = try #require(installs.all.first)
    let installed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(installed["state"] as? String == "paused" && (installed["target"] as? [String: Any])?["address"] as? String == "new")
    #expect((installed["schedule"] as? [String: Any])?["review"] as? Bool == true)
    #expect(Set(writes.compactMap(\.url?.path)).count == 1)
    #expect(store.herdrMainBot(on: b) === bot)
    if choice == .unchanged {
        try await store.undoHerdrMove(record)
        #expect(store.herdrServer(for: bot) == a)
        #expect(store.herdrMainBot(on: a) === bot)
        #expect(store.herdrMainBot(on: b) == nil)
        #expect(restores.all.count == 1)
        #expect(undoRequests.all.map(\.action) == ["suspend", "retire"])
    } else {
        let rejection: HerdrMoveError = choice == .source ? .mainChanged : .undoUnavailable
        await #expect(throws: rejection) { try await store.undoHerdrMove(record) }
        #expect(store.herdrServer(for: bot) == b)
        #expect(store.herdrServer(for: peer) == (choice == .source ? a : b))
        #expect(Array(store.flaggedHerdrBots(on: a).map(\.id)) == (choice == .source ? [peer.id] : []))
        #expect(Array(store.flaggedHerdrBots(on: b).map(\.id)) == (choice == .source ? [bot.id] : [peer.id]))
        let requests = undoRequests.all
        #expect(requests.map(\.action) == ["suspend", "resume"])
        let receipt = try #require(record.receipts.first)
        #expect(requests.allSatisfy { $0.path == "/api/routine-transfers/\(receipt.token.uuidString)" })
        let attempt = try #require(requests.first?.attempt)
        #expect(requests.last?.attempt == attempt)
        #expect(restores.all.isEmpty)
    }
    #expect(!store.routineMovePending(from: a, to: b))
}
