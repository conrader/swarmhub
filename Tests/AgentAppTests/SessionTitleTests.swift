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
    let now = Date(), mine = E2ELive.runNamespace
    #expect(mine.hasPrefix(AppConstants.selfTestPrefix) && mine != AppConstants.selfTestPrefix, "the run's sessions are self-test sessions with a prefix of their own")
    let own: [String: Any] = ["id": "\(mine)agentapp_a", "started_at": now.timeIntervalSince1970 - 60, "last_active": now.timeIntervalSince1970]
    let old: [String: Any] = ["id": "swarmhub-selftest-agentapp_b", "started_at": now.timeIntervalSince1970 - 86_400, "last_active": now.timeIntervalSince1970 - 3_600]
    let busy: [String: Any] = ["id": "swarmhub-selftest-agentapp_c", "started_at": now.timeIntervalSince1970 - 600, "last_active": now.timeIntervalSince1970 - 60]
    // Codex review of uxfix3-e2e: another run that started after this one is not this run's.
    let later: [String: Any] = ["id": "swarmhub-selftest-rffffffff-agentapp_d", "started_at": now.timeIntervalSince1970 - 30, "last_active": now.timeIntervalSince1970 - 5]
    let undated: [String: Any] = ["id": "swarmhub-selftest-agentapp_e"]
    let real: [String: Any] = ["id": "agentapp_f", "started_at": now.timeIntervalSince1970 - 86_400, "last_active": now.timeIntervalSince1970 - 86_400]
    #expect(E2ELive.isDeletable(own, now: now) && E2ELive.isDeletable(old, now: now))
    #expect(!E2ELive.isDeletable(busy, now: now), "another run's session that is still active is left alone")
    #expect(!E2ELive.isDeletable(later, now: now), "a run that started after this one keeps its sessions")
    #expect(!E2ELive.isDeletable(undated, now: now), "a stranger with no times is never taken as quiet")
    #expect(!E2ELive.isDeletable(real, now: now), "a bot's real session is never touched")
}

// Codex review of uxfix3-e2e: a read-back that cannot list the sessions fails the check; it is never an empty list.
@MainActor @Test func theE2ECleanupFailsWhenItCannotReadBack() async throws {
    let lists = ListCount(), now = Date().timeIntervalSince1970
    let own = "\(E2ELive.runNamespace)agentapp_a", other = "swarmhub-selftest-rffffffff-agentapp_b"
    let rows: [[String: Any]] = [["id": own, "started_at": now - 60, "last_active": now],
                                 ["id": other, "started_at": now - 30, "last_active": now - 5],
                                 ["id": "agentapp_real", "started_at": now - 86_400, "last_active": now - 86_400]]
    let page = (try? JSONSerialization.data(withJSONObject: ["data": rows])) ?? Data()
    let (host, backend) = ChatParityServer.serve(features: [:]) { request, _ in
        let path = request.url?.path ?? ""
        if request.httpMethod == "DELETE", path.contains("/api/sessions/") { return .json(200, ["ok": true]) }
        guard request.httpMethod == "GET", path.hasSuffix("/api/sessions") else { return .json(404, ["error": "no route"]) }
        if lists.next() > 1 { return .json(500, ["error": "down"]) }
        return .init(body: page)
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: "e2e-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let run = E2ELive.Run(directory: directory, network: E2ELiveNetwork.shared)
    await E2ELive.cleanSelfTestSessions([backend], run: run, phase: "after")
    let deletes = ChatParityServer.requests(host).filter { $0.method == "DELETE" }.map { $0.path }
    #expect(deletes.count == 1 && deletes.first?.hasSuffix(own) == true, "only this run's own session is deleted: \(deletes)")
    #expect(run.failed == 1 && run.lines.last?.hasPrefix("FAIL cleanup.after") == true && run.lines.last?.contains("read-back") == true, "\(run.lines)")
    await E2ELive.cleanSelfTestSessions([], run: run, phase: "none")
    #expect(run.failed == 2, "no profile to read back is not a pass")
}

private final class ListCount: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
