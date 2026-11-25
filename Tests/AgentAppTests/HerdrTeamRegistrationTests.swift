import Foundation
import Testing
@testable import AgentApp

struct HerdrTeamRegistrationTests {
    typealias Member = HerdrClient.TeamMember
    private let limit = 128 * 1024

    private func member(_ i: Int, _ instructions: String, main: Bool = false) -> Member {
        Member(id: "bot-\(i)", name: "Bot \(i)", agentName: "bot-\(i)", template: "fixture", model: "fixture",
               instructions: instructions, projects: [7, 12], main: main, takesMessages: i.isMultiple(of: 2),
               takesInitiative: true, notifications: false)
    }

    // The original, single-request wire format, independent of the batch builder.
    private func encode(_ bots: [Member]) throws -> Data {
        struct Registration: Encodable { let bots: [Member] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(Registration(bots: bots))
    }

    private func rows(_ data: Data) throws -> [NSDictionary] {
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(envelope.keys) == ["bots"])
        return try #require(envelope["bots"] as? [NSDictionary])
    }

    @Test func encodedBoundaryAndRoleTransfer() throws {
        let escaped = String(repeating: "雪\n\t\"/\\", count: 300)
        let base = (0..<25).map { member($0, escaped, main: $0 == 0) }
        let padding = 128_896 - (try encode(base).count)
        let saved = base.indices.map { i in
            member(i, escaped + String(repeating: "x", count: padding / 25 + (i < padding % 25 ? 1 : 0)), main: i == 0)
        }
        #expect(try encode(saved).count == 128_896)
        let extraSpace = limit - (try encode(saved + [member(25, "")]).count)
        let exact = saved + [member(25, String(repeating: "a", count: extraSpace))]
        #expect(try encode(exact).count == limit)
        #expect(try HerdrClient.teamRegistrationBatches(exact).map(\.body.count) == [limit])

        // "false" takes one more byte than "true", even with identical instructions.
        var demoted = exact
        demoted[0] = member(0, exact[0].instructions)
        #expect(try encode(demoted).count == limit + 1)
        let over = saved + [member(25, String(repeating: "a", count: extraSpace + 1))]
        #expect(try encode(over).count == limit + 1)
        var transferred = saved
        transferred[0] = member(0, saved[0].instructions + "\nAsk Bot 25.")
        transferred.append(member(25, escaped + "\nManage the team.", main: true))
        for roster in [over, demoted, transferred] {
            let batches = try HerdrClient.teamRegistrationBatches(roster)
            #expect(batches.count == 2)
            #expect(batches.allSatisfy { $0.body.count <= limit })
            let sent = try batches.flatMap { try rows($0.body) }
            let expected = try rows(encode(roster.filter(\.main) + roster.filter { !$0.main }))
            #expect(sent == expected) // Includes instructions, model, projects and every switch.
            #expect(sent.first?["main"] as? Bool == roster.contains(where: \.main))
        }
    }

    @Test func batchLimitsAndOversizedSingleton() throws {
        #expect(try HerdrClient.teamRegistrationBatches([]).isEmpty)
        let many = (0..<201).map { member($0, "") }
        #expect(try HerdrClient.teamRegistrationBatches(many).map(\.ids.count) == [200, 1])
        let oversized = member(201, String(repeating: "\"", count: limit / 2))
        #expect(throws: BackendError.self) { try HerdrClient.teamRegistrationBatches(many + [oversized]) }
    }

    @MainActor private func fixture(_ handler: @escaping MockHTTPProtocol.Handler) -> (AppStore, HerdrServer, String) {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let http = MockHTTPProtocol.serve(handler)
        let server = HerdrServer(id: HerdrServer.defaultID, name: "Fixture", kind: .address, address: "http://\(http.host)")
        store.saveHerdrServer(server, token: "fixture")
        store.herdrClientSetup = { $0.session = http.session; $0.following = .polling }
        return (store, server, http.host)
    }

    @MainActor @Test func longMainPersonaIsCappedOnlyOnTheRegistrationWire() async throws {
        let posts = AwaitableLog<Data>()
        let (store, server, host) = fixture { request in
            if request.url?.path == "/api/workspace" { return (200, ["core": "c", "agents": [], "templates": []]) }
            guard request.httpMethod == "POST", request.url?.path == "/api/bots",
                  let data = request.bodyData else { return (404, [:]) }
            posts.append(data)
            guard data.count <= 128 * 1024 else { return (413, [:]) }
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(envelope.keys) == ["bots"], let rows = envelope["bots"] as? [[String: Any]],
                  rows.allSatisfy({ row in
                      guard let instructions = row["instructions"] as? String else { return false }
                      return instructions.utf8.count <= 12 * 1024
                  }) else { return (422, [:]) }
            return (200, [:])
        }
        let persona = String(repeating: "雪\"\\\n🙂", count: 1_300) + "saved persona tail"
        let team = (0..<16).map { Bot(name: "Member \($0)", persona: persona, backend: .herdr) }
        let main = team[15]
        store.bots = team
        store.setCanManageBots(main, true)
        store.aboutYou = String(repeating: "雪", count: 800)
        store.removedBots[server.id] = ["another-installation"]
        var backend = try store.herdrBackend(for: main)
        backend.messageNote = nil
        backend.roster = nil
        let fullLaunch = try #require(backend.launchInstructions)
        #expect(fullLaunch.utf8.count > 12 * 1024)

        #expect(try await store.ensureTeam(server))
        let bodies = posts.all
        #expect(bodies.count > 1)
        let sent = try bodies.flatMap { try rows($0) }
        let expectedIDs = [main.id.uuidString.lowercased()] + team.dropLast().map { $0.id.uuidString.lowercased() }
        #expect(sent.compactMap { $0["id"] as? String } == expectedIDs)
        let instructions = try #require(sent.first?["instructions"] as? String)
        #expect(instructions == HerdrClient.plain(fullLaunch, bytes: 12 * 1024))
        #expect(sent.first?["main"] as? Bool == true && team.allSatisfy { store.bridgeCoordinates($0) })
        #expect(MockHTTPProtocol.recorded(host).compactMap { $0.url?.path } == ["/api/workspace"] + Array(repeating: "/api/bots", count: bodies.count))
        #expect(main.persona == persona)
        try store.saveThrowing()
        let saved = try StoreFile.decode(Data(contentsOf: store.fileURL))
        #expect(saved.bots.first { $0.id == main.id }?.persona == persona)
    }

    @MainActor @Test func partialRegistrationAndRemovalRetryCommitOnlyAfterSuccess() async throws {
        let posts = AwaitableLog<[String]>()
        let removals = LockedTrace()
        let rejectAfterFirst = LockedValue(true)
        let rejectRemoval = LockedValue(true)
        let (store, server, _) = fixture { req in
            let path = req.url?.path ?? ""
            if path == "/api/workspace" { return (200, ["core":"c", "agents":[], "templates":[]]) }
            if path.hasSuffix("/remove") {
                removals.add(path)
                return (rejectRemoval.current ? 503 : 404, [:])
            }
            guard path == "/api/bots", req.httpMethod == "POST", let data = req.bodyData,
                  data.count <= 131_072, let body = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]],
                  let bots = body["bots"] else { return (413, [:]) }
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            #expect(req.value(forHTTPHeaderField: "Origin") == "http://\(req.url!.host!)")
            posts.append(bots.compactMap { $0["id"] as? String })
            return (posts.all.count >= 2 && rejectAfterFirst.current ? 404 : 200, [:])
        }
        let team = (0..<26).map { Bot(name: "Bot \($0)", persona: String(repeating: "a\"\n", count: 1_300), backend: .herdr) }
        team[2].isHidden = true
        let archive = Bot(name: "Archive", backend: .herdr)
        archive.archivedMembers = []
        store.bots = team + [archive]
        let main = team[25]
        store.setCanManageBots(main, true)
        do {
            _ = try await store.ensureTeam(server)
            Issue.record("A later 404 must fail the sync")
        } catch HerdrClient.Failure.http(404, let reason) {
            #expect(reason.contains("POST /api/bots"))
        }
        #expect(posts.all.count == 2 && posts.all.first?.first == main.id.uuidString.lowercased())
        #expect(store.teamSynced[server.id] == nil && !store.bridgeCoordinates(main))
        #expect(removals.read().isEmpty)

        // A new attempt starts at batch zero, but this directory already accepted batch one.
        do {
            _ = try await store.ensureTeam(server)
            Issue.record("An acknowledged batch must rule out legacy fallback on retry")
        } catch HerdrClient.Failure.http(404, _) {}
        #expect(posts.all.count == 3 && posts.all.last == posts.all.first)
        #expect(store.teamSynced[server.id] == nil && !store.bridgeCoordinates(main))

        // Delete a member confirmed by the first batch and transfer the role before retrying.
        let deleted = main.id.uuidString.lowercased()
        store.bots.removeAll { $0 === main }
        store.removedBots[server.id] = [deleted, "someone-elses-bot"]
        store.setCanManageBots(team[0], true)
        store.setCanManageBots(main, true) // A stale editor or pending decision for the deleted manager.
        #expect(!store.createsHerdrBots(main) && store.createsHerdrBots(team[0]))
        _ = rejectAfterFirst.swap(false)
        do {
            _ = try await store.ensureTeam(server)
            Issue.record("A removal failure must fail the sync")
        } catch HerdrClient.Failure.http(503, _) {}
        #expect(store.teamSynced[server.id] == nil && !store.bridgeCoordinates(team[0]))
        _ = rejectRemoval.swap(false)
        let before = posts.all.count
        async let first = store.ensureTeam(server)
        async let second = store.ensureTeam(server)
        let success = try await (first, second)
        #expect(success.0 && success.1)
        let retry = posts.all.dropFirst(before)
        #expect(retry.flatMap { $0 } == team.dropLast().map { $0.id.uuidString.lowercased() })
        #expect(removals.read() == Array(repeating: "/api/bots/\(deleted)/remove", count: 2))
        #expect(team.dropLast().allSatisfy { store.bridgeCoordinates($0) })
        #expect(!store.bridgeCoordinates(archive) && !store.bridgeCoordinates(main))
        let committed = posts.all.count
        #expect(try await store.ensureTeam(server))
        #expect(posts.all.count == committed)
    }

    @MainActor @Test func newMainFirstTurnWaitsForAnOlderPollThenSendsOnce() async throws {
        let registered = AwaitableLog<[String]>()
        let release = DispatchSemaphore(value: 0)
        let message = String(repeating: "m", count: 44)
        let (store, server, host) = fixture { request in
            switch request.url?.path {
            case "/api/workspace":
                return (200, ["core":"c", "agents":[], "templates":[["name":"fixture"]]])
            case "/api/bots":
                guard let data = request.bodyData, data.count <= 131_072,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]],
                      let rows = body["bots"] else { return (413, [:]) }
                registered.append(rows.compactMap { $0["id"] as? String })
                if registered.all.count == 1 { _ = release.wait(timeout: .now() + 10) }
                return (200, [:])
            case "/api/profiles": return (200, [Any]())
            case "/api/agents":
                let body = request.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                #expect((body?["task"] as? String)?.hasSuffix(message) == true)
                return (201, ["address":"t1", "created_ms":1, "state":"live", "name":"fixture"])
            case "/api/history/c/t1/1":
                return (200, ["items":[["id":1, "kind":"task", "text":message], ["id":2, "kind":"reply", "text":"Received"]]])
            default: return (404, [:])
            }
        }
        store.bots = (0..<25).map { Bot(name: "Bot \($0)", persona: String(repeating: "雪\n\"", count: 800), backend: .herdr) }
        let absent = UUID()
        let saved = store.bots.map { $0.id.uuidString.lowercased() } + [absent.uuidString.lowercased()]
        store.defaults.set(saved, forKey: "herdrTeamMembers.\(server.id)")
        store.setCanManageBots(store.bots[0], true)
        let poll = Task { try await store.ensureTeam(server) }
        defer { release.signal() }
        try await registered.wait { !$0.isEmpty }
        let oldMain = store.bots[0]
        var oldSettings = BotEditorFields(bot: oldMain, store: store)
        let new = Bot(name: "New main", backend: .herdr)
        store.bots.append(new)
        store.setCanManageBots(new, true)
        oldSettings.name = "Former main"
        oldSettings.apply(to: oldMain, store: store, avatarTouched: false)
        #expect(store.herdrMainBot(on: server) === new && !store.createsHerdrBots(oldMain))
        store.launchWorkEnabled = true
        let request = AgentRequest(sessionID: "fixture", systemPrompt: "", messages: [("user", message)])
        let send = Task {
            let stream = try await store.herdrBackend(for: new).send(request)
            var reply = ""
            for try await event in stream {
                if case .replace(let text) = event { reply = text }
            }
            return reply
        }
        release.signal()
        #expect(try await poll.value)
        #expect(try await send.value == "Received")
        let id = new.id.uuidString.lowercased()
        let firstNew = try #require(registered.all.firstIndex { $0.contains(id) })
        #expect(registered.all[firstNew...].flatMap { $0 } == [id] + store.bots.dropLast().map { $0.id.uuidString.lowercased() })
        #expect(store.bridgeCoordinates(new))
        #expect(store.teamPreviouslyRegistered(absent, on: server))
        let posts = MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }.compactMap { $0.url?.path }
        #expect(posts == Array(repeating: "/api/bots", count: registered.all.count) + ["/api/agents"])
    }

    @MainActor @Test func firstTurnPropagatesRegistrationAuthAndSizeErrors() async throws {
        let status = LockedValue(401)
        let (store, server, host) = fixture { req in
            if req.url?.path == "/api/workspace" { return (200, ["core":"c", "agents":[], "templates":[]]) }
            return (status.current, Data("fixture".utf8))
        }
        let bot = Bot(name: "Existing", backend: .herdr)
        store.bots = [bot]
        store.defaults.set([bot.id.uuidString.lowercased()], forKey: "herdrTeamMembers.\(server.id)")
        store.launchWorkEnabled = true
        let message = String(repeating: "m", count: 44)
        let request = AgentRequest(sessionID: "fixture", systemPrompt: "", messages: [("user", message)])
        for (code, failure) in [(401, HerdrClient.Failure.unauthorized), (403, .refusedHost)] {
            _ = status.swap(code)
            await #expect(throws: failure) { _ = try await store.herdrBackend(for: bot).send(request) }
        }
        let new = Bot(name: "New", backend: .herdr)
        store.bots.append(new)
        _ = status.swap(413)
        do {
            _ = try await store.herdrBackend(for: new).send(request)
            Issue.record("A failed registration must hold the new bot's first turn")
        } catch HerdrClient.Failure.http(413, let reason) {
            #expect(reason.contains("POST /api/bots") && reason.contains("413"))
        }
        #expect(MockHTTPProtocol.recorded(host).compactMap { $0.url?.path } ==
                Array(repeating: ["/api/workspace", "/api/bots"], count: 3).flatMap { $0 })
    }

    @MainActor @Test func firstRegistration404KeepsLegacyCoordination() async throws {
        let (store, server, host) = fixture { request in
            if request.url?.path == "/api/workspace" { return (200, ["core":"c", "agents":[], "templates":[]]) }
            return (404, [:])
        }
        let bot = Bot(name: "Legacy", backend: .herdr)
        store.bots = [bot]
        let first = try await store.ensureTeam(server)
        let again = try await store.ensureTeam(server)
        #expect(!first && !again && !store.bridgeCoordinates(bot))
        #expect(MockHTTPProtocol.recorded(host).compactMap { $0.url?.path } == ["/api/workspace", "/api/bots"])
    }

    @MainActor @Test(arguments: [0, 503])
    func firstRegistration404AfterTransientFailureResumesLegacySends(_ firstStatus: Int) async throws {
        let status = LockedValue(firstStatus)
        let message = "Check whether my first message arrived on the old bridge."
        let (store, server, host) = fixture { request in
            switch request.url?.path {
            case "/api/workspace": return (200, ["core": "c", "agents": [], "templates": [["name": "fixture"]]])
            case "/api/bots":
                if status.current == 0 { return (0, URLError(.networkConnectionLost)) }
                return (status.current, [:])
            case "/api/profiles": return (200, [Any]())
            case "/api/agents":
                let body = request.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let task = body?["task"] as? String
                #expect(task?.contains(HerdrBotMessage.marker) == true && task?.hasSuffix(message) == true)
                return (201, ["address": "t1", "created_ms": 1, "state": "live", "name": "fixture"])
            case "/api/history/c/t1/1":
                return (200, ["items": [["id": 1, "kind": "task", "text": message],
                                        ["id": 2, "kind": "reply", "text": "Received"]]])
            default: return (404, [:])
            }
        }
        let bot = Bot(name: "Legacy", backend: .herdr)
        store.bots = [bot]
        await store.syncTeam(server)
        let pendingKey = "herdrTeamPendingMembers.\(server.id)"
        #expect(store.defaults.stringArray(forKey: pendingKey) == [bot.id.uuidString.lowercased()])
        #expect(store.teamErrors[server.id] != nil && !store.bridgeCoordinates(bot))

        _ = status.swap(404)
        store.launchWorkEnabled = true
        let request = AgentRequest(sessionID: "fixture", systemPrompt: "", messages: [("user", message)])
        let stream = try await store.herdrBackend(for: bot).send(request)
        var reply = ""
        for try await event in stream {
            if case .replace(let text) = event { reply = text }
        }
        #expect(reply == "Received")
        let cached = try await store.ensureTeam(server)
        #expect(!cached && !store.bridgeCoordinates(bot))
        #expect(store.defaults.object(forKey: pendingKey) == nil && store.teamErrors[server.id] == nil)
        let posts = MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }
        #expect(posts.compactMap { $0.url?.path } == ["/api/bots", "/api/bots", "/api/agents"])
    }

    @MainActor @Test func deletionAfterLostRegistrationResponseCleansUpOnlyTheAttemptedBot() async throws {
        let (store, server, host) = fixture { request in
            switch request.url?.path {
            case "/api/workspace": return (200, ["core":"c", "agents":[], "templates":[]])
            case "/api/bots": return (0, URLError(.networkConnectionLost))
            default: return (404, [:])
            }
        }
        let bot = Bot(name: "Pending", backend: .herdr)
        store.bots = [bot]
        await #expect(throws: URLError.self) { _ = try await store.ensureTeam(server) }
        #expect(!store.bridgeCoordinates(bot) && store.teamSynced[server.id] == nil)
        let id = bot.id.uuidString.lowercased()
        store.bots = []
        store.removedBots[server.id] = [id, "never-attempted"]
        #expect(try await store.ensureTeam(server))
        let paths = MockHTTPProtocol.recorded(host).compactMap { $0.url?.path }
        #expect(paths == ["/api/workspace", "/api/bots", "/api/bots/\(id)/remove"])
    }
}
