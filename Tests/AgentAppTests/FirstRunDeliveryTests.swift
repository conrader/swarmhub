import Foundation
import Testing
@testable import AgentApp

@MainActor private func deliveryStore(backend: (any AgentBackend)? = nil) -> AppStore {
    let factory: ((Bot) throws -> any AgentBackend)? = backend.map { value in { _ in value } }
    return AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: factory,
                    keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
}

@Test @MainActor func anAcceptedTaskIsObservedAgainAfterAReadFailureWithoutResubmission() async throws {
    let bot = Bot(name: "Delivery", backend: .herdr)
    let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    let accepted = LockedValue(false)
    let readFailed = LockedValue(false)
    let (host, session) = MockHTTPProtocol.serve { request in
        let path = request.url?.path ?? ""
        if path == "/api/workspace" {
            return (200, ["core": "test-core", "agents": [["address": "t7", "name": name, "created_ms": 9,
                "state": "live", "status": ["state": "idle"]]], "templates": []])
        }
        if path == "/api/agents/t7/9/messages" {
            _ = accepted.swap(true)
            return (200, ["queued": false])
        }
        if path == "/api/history/test-core/t7/9" {
            if !accepted.current { return (200, ["items": []]) }
            if !readFailed.swap(true) { return (0, URLError(.notConnectedToInternet)) }
            return (200, ["items": [["id": 1, "kind": "reply", "text": "One delivered answer"]]])
        }
        return (200, [:])
    }
    var client = HerdrClient(baseURL: URL(string: "https://\(host)")!, token: "fixture", session: session)
    client.following = .polling
    client.pollInterval = .milliseconds(1)
    let backend = HerdrBackend(client: client, botName: bot.name, botID: bot.id, template: nil)
    let store = deliveryStore(backend: backend)
    store.bots = [bot]; store.selectedBot = bot
    store.sendRetryDelays = [.milliseconds(1)]
    #expect(store.send(text: "one task"))
    try await waitUntil { store.runningTurns.isEmpty }
    #expect(readFailed.current)
    #expect(bot.messages.last?.content == "One delivered answer")
    #expect(MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }.count == 1)
}

@Test(arguments: [false, true])
@MainActor func imagesAndTextFilesUseTheExactCoreAndKeepTheirContents(firstTurn: Bool) async throws {
    let id = UUID(), name = HerdrBackend.agentName(botName: "Attachments", botID: id)
    let sent = LockedValue(false)
    let captured = LockedValue<Data?>(nil)
    let attachmentRoute = firstTurn ? "/api/agents/with-files" : "/api/agents/t7/50/messages/with-files"
    let (host, session) = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/workspace":
            let agents: [[String: Any]] = firstTurn ? [] : [["address": "t7", "name": name, "created_ms": 50, "state": "live"]]
            return (200, ["core": "test-core", "attachments": true, "launch_attachments": true,
                          "agents": agents, "templates": [["name": "opencode"]]])
        case "/api/profiles": return (200, [])
        case attachmentRoute:
            _ = captured.swap(request.bodyData)
            _ = sent.swap(true)
            if firstTurn { return (201, ["address": "t7", "name": name, "created_ms": 50, "state": "live"]) }
            return (200, ["queued": false])
        case "/api/history/test-core/t7/50":
            return (200, ["items": sent.current ? [["id": 2, "kind": "reply", "text": "File received"]] : []])
        default: return (200, [:])
        }
    }
    var client = HerdrClient(baseURL: URL(string: "https://\(host)")!, token: "fixture", session: session)
    client.following = .polling
    let backend = HerdrBackend(client: client, botName: "Attachments", botID: id, template: nil)
    let longDocument = String(repeating: "x", count: 12_000) + "Final question"
    let image = Data([0x89, 0x50, 0x4E, 0x47])
    let request = AgentRequest(sessionID: id.uuidString, systemPrompt: "", messages: [("user", "")],
        images: [AttachmentEncoder.dataURL(mime: "image/png", data: image)],
        files: [.init(name: "notes.txt", mime: "text/plain", data: Data(longDocument.utf8))])
    for try await _ in try await backend.send(request) {}
    let body = try #require(captured.current)
    #expect(body.range(of: Data(longDocument.utf8)) != nil && body.range(of: image) != nil)
    #expect(String(decoding: body, as: UTF8.self).contains("\"expected_core\":\"test-core\""))
    #expect(String(decoding: body, as: UTF8.self).contains("Read the attached files."))
    #expect(MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }.count == 1)
}

@Test(arguments: [false, true])
@MainActor func groupDeliveryAndStopAreIndependentOfTheDirectSession(stopBeforePost: Bool) async throws {
    let bot = Bot(name: "Runs", backend: .herdr), group = GroupChat(name: "Group", memberIDs: [])
    let directName = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    let sessionID = GroupRouting.sessionID(group: group.id, bot: bot.id)
    let groupName = try #require(HerdrBackend.groupRuntimeName(sessionID: sessionID, botID: bot.id))
    #expect(groupName != directName)
    let pauseNextRequest = LockedValue(false)
    let gate = AwaitableLog<String>()
    let groupPosted = LockedValue(false)
    let canFinish = LockedValue(false)
    let (host, session) = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/workspace":
            return (200, ["core": "test-core", "templates": [], "agents": [
                ["name": directName, "address": "t1", "created_ms": 3, "state": "live"],
                ["name": groupName, "address": "t2", "created_ms": 4, "state": "live"]]])
        case "/api/history/test-core/t2/4/draft":
            _ = pauseNextRequest.swap(stopBeforePost)
            return (200, ["tools": []])
        case "/api/agents/t2/4/messages":
            _ = groupPosted.swap(true)
            return (200, ["queued": false])
        case "/api/history/test-core/t2/4":
            guard groupPosted.current else { return (200, ["items": []]) }
            gate.append("following reply")
            return (200, ["items": canFinish.current ? [["id": 9, "kind": "reply", "text": "Group answer"]] : []])
        default: return (200, [:])
        }
    }
    var client = HerdrClient(baseURL: URL(string: "https://\(host)")!, token: "fixture", session: session)
    client.prepare = {
        if pauseNextRequest.swap(false) {
            // The pre-send draft read is complete. Hold preparation of the message POST.
            gate.append("preparing message")
            // A shared connection can finish preparing even after its caller has been cancelled.
            try await Task { try await gate.wait { $0.contains("released") } }.value
        }
        return 443
    }
    client.following = .polling
    client.pollInterval = .milliseconds(1)
    let backend = HerdrBackend(client: client, botName: bot.name, botID: bot.id, template: nil)
    let groupStream = try await backend.send(.init(sessionID: sessionID, systemPrompt: "", messages: [("user", "Group question")]))
    let listener = Task { for try await _ in groupStream {} }
    defer { gate.append("released"); listener.cancel() }
    if stopBeforePost {
        try await gate.wait { $0.contains("preparing message") }
    } else {
        // The first reply poll follows the group's acknowledged message POST.
        try await gate.wait { $0.contains("following reply") }
    }
    #expect(try await backend.stopTarget(sessionID: bot.id.uuidString) == .serverRun("test-core/t1/3"))
    #expect(try await backend.stopTarget(sessionID: sessionID) == .serverRun("test-core/t2/4"))
    #expect(try await backend.cancel(sessionID: sessionID) == .requested)
    _ = canFinish.swap(true)
    gate.append("released")
    try await listener.value
    let posts = MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }.compactMap { $0.url?.path }
    if stopBeforePost {
        #expect(posts == ["/api/agents/t2/4/interrupt"])
    } else {
        #expect(posts == ["/api/agents/t2/4/messages", "/api/agents/t2/4/interrupt"])
    }
}

@Test @MainActor func composerAttachmentDraftsFollowTheConversationAndOverlongTextStaysUnsent() throws {
    let store = deliveryStore(backend: TestBackend())
    let a = Bot(name: "One", backend: .herdr), b = Bot(name: "Two", backend: .herdr)
    store.bots = [a, b]
    let group = GroupChat(name: "Group", memberIDs: [a.id, b.id])
    let file = ChatAttachment(id: UUID(), kind: .text, name: "Draft.txt", mimeType: "text/plain", byteCount: 1, text: "a")
    store.attachmentIntake(for: a.id).items = [file]
    store.attachmentIntake(for: group.id).items = [file]
    #expect(store.attachmentIntake(for: b.id).items.isEmpty)
    #expect(store.attachmentIntake(for: a.id).items == [file] && store.attachmentIntake(for: group.id).items == [file])
    store.selectedBot = b
    let oversized = String(repeating: "🚀", count: 2010) + "Do not truncate this."
    #expect(!store.send(text: oversized))
    #expect(b.messages.isEmpty && store.errorMessage?.contains("byte limit") == true)
    let history = [ChatMessage(role: .user, content: String(repeating: "a", count: 9000))]
    let current = ChatMessage(role: .user, content: String(repeating: "a", count: 7900) + "Final question")
    let context = try GroupRouting.herdrContext(for: .init(id: b.id, name: b.name), groupName: group.name, members: [],
        messages: history + [current], current: current, limit: 8000, userName: "Person")
    #expect(context.hasSuffix(current.content) && context.utf8.count <= 8000)
}

@Test @MainActor func removingTheImplicitFirstHostClearsOnlyItsProjectGrants() throws {
    let store = deliveryStore()
    let first = HerdrServer(id: "first", name: "One", kind: .address, address: "http://127.0.0.1:8787")
    let second = HerdrServer(id: "second", name: "Two", kind: .address, address: "http://127.0.0.1:8788")
    store.saveHerdrServers([first, second])
    let implicit = Bot(name: "Implicit", backend: .herdr), stays = Bot(name: "Stays", backend: .herdr)
    store.bots = [implicit, stays]
    store.setHerdrServer(second.id, for: stays)
    let project = HerdrBotProject(id: 1, name: "Other", machine: "Fixture")
    store.setHerdrProjects([project], for: implicit)
    store.setHerdrProjects([project], for: stays)
    store.removeHerdrServer(first)
    #expect(store.herdrServer(for: implicit) == second && store.herdrProjects(for: implicit).isEmpty)
    #expect(store.herdrProjects(for: stays) == [project])
}

@Test @MainActor func aCompletedDirectReplyBecomesUnreadInAnotherChat() async throws {
    let store = deliveryStore(backend: TestBackend())
    let a = Bot(name: "One", backend: .herdr), b = Bot(name: "Two", backend: .herdr)
    store.bots = [a, b]; store.selectedBot = a
    #expect(store.send(text: "One reply"))
    store.open(b)
    try await waitUntil { store.runningTurns.isEmpty }
    #expect(a.unreadCount == 1 && b.unreadCount == 0)
}

@Test func aWarmStartAndAFirstSendCarryTheSameFullBotWorkspaceID() async throws {
    let id = UUID(), name = HerdrBackend.agentName(botName: "Workspace", botID: id)
    let sentIDs = AwaitableLog<String>()
    let (host, session) = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/workspace":
            return (200, ["core": "test-core", "bot_workspaces": true, "agents": [], "templates": [["name": "claude"]]])
        case "/api/profiles": return (200, [])
        case "/api/agents":
            if let data = request.bodyData,
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = body["workspace_id"] as? String { sentIDs.append(id) }
            return (200, ["core": "test-core", "address": "t7", "created_ms": 1, "state": "live", "name": name])
        default: return (404, [:])
        }
    }
    let client = HerdrClient(baseURL: URL(string: "https://\(host)")!, token: "fixture", session: session)
    _ = try await client.warm(name: name, template: "claude", workspaceID: id)
    _ = try await client.deliver("First task", name: name, template: "claude", workspaceID: id)
    #expect(sentIDs.all == Array(repeating: id.uuidString.lowercased(), count: 2))
}
