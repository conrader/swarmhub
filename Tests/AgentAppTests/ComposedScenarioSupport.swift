import Foundation
import Testing
@testable import AgentApp

// backlog6: fixtures for the composed steer / overflow / internal-session scenarios (`ComposedScenarioTests`).
// Every name is synthetic and unique per test (`Fixture …-<hex>`), every session lives only in the in-process stub,
// and the store's folder is removed by `ComposedWorld.tearDown()`. No real gateway, bot or Mac session is touched.

/// What the stub box answers on one chat-stream request.
enum ComposedTurn {
    case reply(String), status(Int), overflow(String)
    /// The manager's `skills_installed` answer for `profile` (the fixture's unique manager profile).
    case installed

    func reply(profile: String) -> ChatParityServer.Reply {
        switch self {
        case .installed:
            return Self.reply("Installed.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"\(profile)\",\"skills\":[{\"name\":\"swarmhub-manager\",\"version\":\"1.2.0\"}]}\n```").reply(profile: profile)
        case .reply(let text):
            return .sse([("assistant.delta", ["delta": text]), ("assistant.completed", ["content": text, "completed": true]), ("run.completed", ["completed": true])])
        case .status(let code): return .json(code, ["error": ["message": "Service unavailable"]])
        case .overflow(let text):
            return .sse([("assistant.completed", ["content": text, "completed": false, "partial": true, "failed": true]), ("run.failed", ["completed": false, "partial": true])])
        }
    }
}

/// Hermes 0.22.0's overflow copy (agent/turn_failure_copy.py); the app must never show its slash-command advice.
let composedOverflowCopy = "This conversation has grown too long for gpt-6.1-sol to read, and Hermes couldn't shrink it enough automatically. Start a new session with /new (your history is kept), or try /compress once more. Switching to a model with a bigger context window also works."

/// A door the store's retry wait stops at until the test opens it, so a setup turn can be held mid-retry
/// deterministically (`AppStore.setupRetrySleep`). It counts the arrivals.
actor RetryGate {
    private var open = false, waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func pass() async {
        arrivals += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// A Hermes box behind `ChatParityServer` with `run_steer` on: setup sessions (`agentapp_setup_`) answer from
/// `install`, every other session from `chat`, each in order. It records sessions created and deleted.
final class ComposedBox: @unchecked Sendable {
    let host: String, backend: HermesBackend, profile: String
    private let lock = NSLock()
    private var installIndex = 0, chatIndex = 0
    init(install: [ComposedTurn], chat: [ComposedTurn], profile: String) {
        self.profile = profile
        let ref = BoxRef()
        (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true, "run_steer": true]) { request, body in
            ref.box?.answer(request, body) ?? .json(500, ["error": "gone"])
        }
        self.install = install; self.chat = chat
        ref.box = self
    }
    private final class BoxRef: @unchecked Sendable { weak var box: ComposedBox? }
    private let install: [ComposedTurn], chat: [ComposedTurn]

    private func answer(_ request: URLRequest, _ body: [String: Any]?) -> ChatParityServer.Reply {
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            let setup = path.contains("agentapp_setup_")
            let turn: ComposedTurn = lock.withLock {
                if setup { defer { installIndex += 1 }; return installIndex < install.count ? install[installIndex] : .status(500) }
                defer { chatIndex += 1 }; return chatIndex < chat.count ? chat[chatIndex] : .reply("extra")
            }
            return turn.reply(profile: profile)
        }
        if path.hasSuffix("/steer") { return .json(200, ["accepted": true]) }
        if path == "/api/sessions", request.httpMethod == "POST" { return .json(201, ["session": ["id": body?["id"] as? String ?? "s-new"]]) }
        if request.httpMethod == "DELETE" { return .json(200, ["deleted": true]) }
        if request.httpMethod == "GET", path.hasPrefix("/api/sessions/"), path.hasSuffix("/messages") { return .json(200, ["object": "list", "data": [Any]()]) }
        return .json(404, ["error": "no route"])
    }

    /// Chat-stream requests in order: the session each went to and the text it carried.
    var streams: [(session: String, input: String)] {
        ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { request in
            let session = request.path.replacingOccurrences(of: "/api/sessions/", with: "").replacingOccurrences(of: "/chat/stream", with: "")
            let input = (request.body?["input"] as? String) ?? ((request.body?["input"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "")
            return (session.removingPercentEncoding ?? session, input)
        }
    }
    var steerRequests: Int { ChatParityServer.requests(host).filter { $0.path.hasSuffix("/steer") }.count }
    var createdSetupSessions: [String] {
        ChatParityServer.requests(host).filter { $0.method == "POST" && $0.path == "/api/sessions" }.compactMap { $0.body?["id"] as? String }.filter { $0.contains("agentapp_setup_") }
    }
    var deletedSessions: Set<String> {
        Set(ChatParityServer.requests(host).filter { $0.method == "DELETE" }.map { request in
            let path = request.path.removingPercentEncoding ?? request.path
            return path.replacingOccurrences(of: "/api/sessions/", with: "")
        })
    }
    /// Every request body and path as one text, to prove a string never reached this box.
    var wire: String {
        ChatParityServer.requests(host).map { request in
            request.path + " " + (request.body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }.joined(separator: "\n")
    }
}

private let fixtureSkill = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.2.0")!,
                                        template: "---\nname: swarmhub-manager\ndescription: \"Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.2.0\n---\n\n{{MANAGER_TEXT}}\n")

/// One store with a manager on the stub box and, optionally, a worker on its own connection driven by
/// `ScriptedTurnBackend`. Unique names and sessions per world.
@MainActor final class ComposedWorld {
    let tag: String
    let box: ComposedBox, worker: ScriptedTurnBackend, gate: RetryGate
    let store: AppStore, manager: Bot, other: Bot
    let storeURL: URL
    var mainSession: String { "fixture-main-\(tag)" }
    var workerSession: String { "fixture-worker-\(tag)" }

    init(install: [ComposedTurn], chat: [ComposedTurn] = []) {
        let tag = String(UUID().uuidString.lowercased().prefix(8)), workerProfile = "fixture-worker-\(tag)", gate = RetryGate(), url = temporaryStore()
        let box = ComposedBox(install: install, chat: chat, profile: "fixture-mgr-\(tag)"), worker = ScriptedTurnBackend()
        let store = AppStore(storeURL: url, autoConfigureHermes: false,
                             backendFactory: { bot in bot.hermesProfile == workerProfile ? worker : box.backend },
                             keyStore: InMemoryKeyStore(["hermes.fixture-mgr-\(tag)": "k", "hermes.\(workerProfile)": "k"]), defaults: isolatedDefaults())
        store.managerTemplateOverride = "COMPOSED-\(tag) you are {{MANAGER}} ({{MANAGER_ENV}})"
        store.skillLibraryOverride = [fixtureSkill]
        store.setupRetrySleep = { _ in await gate.pass() }
        let manager = Bot(name: "Fixture Manager \(tag)", persona: "You are a fixture.", backend: .hermes, hermesProfile: "fixture-mgr-\(tag)")
        manager.canManageBots = true; manager.hermesSessionID = "fixture-main-\(tag)"
        let other = Bot(name: "Fixture Worker \(tag)", backend: .hermes, hermesProfile: workerProfile, hermesSessionID: "fixture-worker-\(tag)")
        other.hermesBaseURL = "https://worker-\(tag).invalid/v1"
        store.bots = [manager, other]; store.selectedBot = manager
        self.tag = tag; self.gate = gate; self.storeURL = url; self.box = box; self.worker = worker
        self.store = store; self.manager = manager; self.other = other
    }

    /// Waits until the manager's install attempt `n` failed and the turn is held in its retry wait.
    func waitForRetry(_ count: Int) async throws { try await waitUntil { await self.gate.arrivals >= count } }

    /// Types in `bot`'s chat as the user would (the window shows that chat).
    @discardableResult func type(_ text: String, in bot: Bot) -> Bool {
        store.selectedBot = bot; store.openThreadID = nil
        return store.send(text: text)
    }

    /// No modal alert, and no row repeats Hermes' slash-command advice.
    func noPopup() -> Bool { store.errorMessage == nil && store.modalErrorMessage == nil }
    func noSlashAdvice(_ bot: Bot) -> Bool { !bot.messages.contains { $0.content.contains("/new") || $0.content.contains("/compress") } }

    /// The manager's own conversation as it would be sent: setup rows never part of it.
    func managerHistory() -> [(role: String, content: String)] {
        store.chatHistory(manager, excluding: ChatMessage(role: .assistant, content: ""))
    }

    func tearDown() {
        store.save()
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }
}
