import Foundation
import Testing
@testable import AgentApp

// uxfix3: Hermes refuses a session title another session holds (400 `invalid_title`; live 27 Oct, Konrad's own app:
// "Title 'Jarvis' is already in use by session swarmhub-selftest-…"). The session is created with a unique title, then
// with none: never the alert. A self-test store's sessions never take a real bot's title. And the e2e run's cleanup
// deletes only self-test sessions that are its own or long quiet.

@Test func aTakenTitleIsRetriedWithAUniqueOneNeverAnError() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        guard request.url?.path == "/api/sessions", request.httpMethod == "POST" else { return .json(404, ["error": "no route"]) }
        if (body?["title"] as? String) == "Jarvis" {
            return .json(400, ["error": ["message": "Title 'Jarvis' is already in use by session swarmhub-selftest-agentapp_2bab3066", "code": "invalid_title"]])
        }
        return .json(200, ["session": ["id": body?["id"] as? String ?? "new"]])
    }
    let id = try await backend.createSession(title: "Jarvis", systemPrompt: "p", id: "agentapp_1234abcd-0000-0000-0000-00000000beef")
    #expect(id == "agentapp_1234abcd-0000-0000-0000-00000000beef")
    let titles = ChatParityServer.requests(host).filter { $0.path == "/api/sessions" }.compactMap { $0.body?["title"] as? String }
    #expect(titles == ["Jarvis", "Jarvis · 0000beef"])
}

@Test func whenEveryTitleIsTakenTheSessionGoesWithoutOne() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        guard request.url?.path == "/api/sessions" else { return .json(404, ["error": "no route"]) }
        if let title = body?["title"] as? String, !title.isEmpty { return .json(400, ["error": ["message": "taken", "code": "invalid_title"]]) }
        return .json(200, ["session": ["id": "s-1"]])
    }
    #expect(try await backend.createSession(title: "Jarvis", systemPrompt: "p", id: "s-1") == "s-1")
    #expect(ChatParityServer.requests(host).filter { $0.path == "/api/sessions" }.compactMap { $0.body?["title"] as? String }.last == "")
}

@Test func anExistingSessionIsStillReused() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        request.url?.path == "/api/sessions" ? .json(409, ["error": ["message": "Session already exists: s-1", "code": "session_exists"]]) : .json(404, ["error": "no route"])
    }
    #expect(try await backend.createSession(title: "Jarvis", systemPrompt: "p", id: "s-1") == "s-1")
    #expect(ChatParityServer.requests(host).filter { $0.path == "/api/sessions" }.count == 1, "not a title clash: no retry")
}

@Test func titleClashesAreOnlyInvalidTitle() {
    #expect(HermesBackend.isTitleClash(400, "Title 'Jarvis' is already in use (invalid_title)"))
    #expect(HermesBackend.isTitleClash(409, "taken (invalid_title)"))
    #expect(!HermesBackend.isTitleClash(409, "Session already exists: s (session_exists)"))
    #expect(!HermesBackend.isTitleClash(500, "invalid_title"))
    #expect(HermesBackend.sessionTitles("", id: "x") == [""])
}

@MainActor @Test func aSelfTestStoreNeverTakesARealBotsTitle() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    #expect(store.sessionTitle("Jarvis", id: "agentapp_x") == "Jarvis", "the real app keeps the bot's name")
    store.sessionNamespace = AppConstants.selfTestPrefix
    let title = store.sessionTitle("Jarvis", id: "swarmhub-selftest-agentapp_2bab3066-aaaa-bbbb-cccc-1234567890ab")
    #expect(title == "[selftest] Jarvis 567890ab")
}

@Test func theE2ECleanupDeletesOnlyItsOwnOrQuietSelfTestSessions() {
    let now = Date()
    let mine: [String: Any] = ["id": "swarmhub-selftest-a", "started_at": E2ELive.runStart.timeIntervalSince1970 + 30, "last_active": now.timeIntervalSince1970]
    let old: [String: Any] = ["id": "swarmhub-selftest-b", "started_at": now.timeIntervalSince1970 - 86_400, "last_active": now.timeIntervalSince1970 - 3_600]
    let busy: [String: Any] = ["id": "swarmhub-selftest-c", "started_at": E2ELive.runStart.timeIntervalSince1970 - 600, "last_active": now.timeIntervalSince1970 - 60]
    #expect(E2ELive.isDeletable(mine, now: now) && E2ELive.isDeletable(old, now: now))
    #expect(!E2ELive.isDeletable(busy, now: now), "another run's session that is still active is left alone")
}
