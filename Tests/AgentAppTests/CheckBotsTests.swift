import Foundation
import Testing
@testable import AgentApp

/// `grok-jarvis` is multiplexed; `grok-doc` is answered by the default agent (prefix ignored).
private func checkBotsServer() -> (host: String, session: URLSession) {
    MockHermesProtocol.serve { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "p" else { return (404, ["error": "no route"]) }
        switch parts[2...].joined(separator: "/") {
        case "v1/models": return (200, ["data": [["id": parts[1] == "grok-jarvis" ? "grok-jarvis" : "hermes-agent"]]])
        case "v1/capabilities": return (200, ["features": ["session_chat_streaming": true, "jobs": false, "run_stop": true]])
        case "api/jobs" where parts[1] == "grok-jarvis":
            return (200, ["jobs": [jobPayload(id: "0123456789ab", name: "Morning"), jobPayload(id: "0123456789ac", name: "Night", enabled: false)]])
        default: return (404, ["error": "no route"])
        }
    }
}

@MainActor private func checkBotsStore(host: String, session: URLSession, keys: [String: String]) -> AppStore {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(keys), defaults: isolatedDefaults(), hermesSession: session)
    store.bots = ["grok-jarvis", "grok-doc", "grok-vised"].map { profile in
        let bot = Bot(name: HermesProfileNaming.botName(forProfile: profile), backend: .hermes, hermesProfile: profile)
        bot.hermesBaseURL = "https://\(host)/v1"
        return bot
    } + [Bot(name: "Mock", backend: .mock)]
    return store
}

@MainActor @Test func checkBotsLineFormat() {
    let ok = HeadlessCommands.BotCheck(name: "Jarvis", profile: "grok-jarvis", key: .present, modelID: "grok-jarvis", modelMatches: true, sessionChatStreaming: true, jobs: false)
    #expect(HeadlessCommands.line(ok) == "Jarvis | grok-jarvis | key: present | models: grok-jarvis (match) | caps: session_chat_streaming=true, jobs=false, run_steer=n/a, session_fork=n/a")
    let missing = HeadlessCommands.BotCheck(name: "Vised", profile: "grok-vised", key: .missing, problem: "no key")
    #expect(HeadlessCommands.line(missing) == "Vised | grok-vised | key: missing | models: - (no key) | caps: session_chat_streaming=n/a, jobs=n/a, run_steer=n/a, session_fork=n/a")
    #expect(!missing.ok && ok.ok)
    #expect(HeadlessCommands.jobsFlag(["jobs_api": true]) == true && HeadlessCommands.jobsFlag([:]) == nil)
}

@MainActor @Test func checkBotsReportsMatchMismatchAndMissingKey() async {
    let (host, session) = checkBotsServer()
    let store = checkBotsStore(host: host, session: session, keys: ["hermes.grok-jarvis": "fixture-jarvis", "hermes.grok-doc": "fixture-doc"])
    var lines: [String] = []
    let code = await HeadlessCommands.checkBots(store: store, chat: nil, output: { lines.append($0) })
    #expect(code == 1)
    #expect(lines == [
        "Jarvis | grok-jarvis | key: present | models: grok-jarvis (match) | caps: session_chat_streaming=true, jobs=false, run_steer=n/a, session_fork=n/a | routines: 2 (1 paused)",
        "Doc | grok-doc | key: present | models: hermes-agent (MISMATCH) | caps: session_chat_streaming=true, jobs=false, run_steer=n/a, session_fork=n/a | routines: no jobs API",
        "Vised | grok-vised | key: missing | models: - (no key) | caps: session_chat_streaming=n/a, jobs=n/a, run_steer=n/a, session_fork=n/a",
        "Checked 3 Hermes bots: 1 OK, 2 failed",
    ])
    #expect(!lines.joined().contains("fixture-"))
    let paths = MockHermesProtocol.recorded(host).map { "\($0.httpMethod ?? "") \($0.url!.path)" }
    #expect(paths == ["GET /p/grok-jarvis/v1/models", "GET /p/grok-jarvis/v1/capabilities", "GET /p/grok-jarvis/api/jobs", "GET /p/grok-doc/v1/models", "GET /p/grok-doc/v1/capabilities", "GET /p/grok-doc/api/jobs"], "jobs are only listed")
    #expect(MockHermesProtocol.recorded(host).allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer fixture-") == true })
}

@MainActor @Test func checkBotsChatUsesTheComposerSendPath() async throws {
    let backend = TestBackend(transport: .nativeSessions, streamMode: .response("Torvli OK"))
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    store.bots = [jarvis]
    var lines: [String] = []
    let code = await HeadlessCommands.chatOnce(store: store, botName: "jarvis", text: "Reply with exactly: Torvli OK", timeout: .seconds(5), output: { lines.append($0) })
    let session = "agentapp_\(jarvis.id.uuidString.lowercased())"
    #expect(code == 0)
    #expect(lines == ["Chat Jarvis | session \(session) | reply: Torvli OK"])
    #expect(await backend.recordedCalls() == ["capabilities", "create:\(session)", "send"])
    #expect(jarvis.messages.map(\.content) == ["Reply with exactly: Torvli OK", "Torvli OK"])

    var missing: [String] = []
    #expect(await HeadlessCommands.chatOnce(store: store, botName: "Nobody", text: "hi", timeout: .seconds(1), output: { missing.append($0) }) == 1)
    #expect(missing == ["Chat failed: no Hermes bot named Nobody"])
}
