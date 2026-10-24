import Foundation
import Testing
@testable import AgentApp

// autoctx1: installs never run in the manager's main session, and a chat that outgrew the model's context compacts once,
// then continues in a new session and resends, all without asking the user to type /new or /compress. Synthetic Hermes
// servers only (shapes of gateway/platforms/api_server.py: assistant.completed with completed=false, then run.failed).

private let marker = "AUTOCTX1-MANAGER"
private let skill = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.2.0")!,
                                 template: "---\nname: swarmhub-manager\ndescription: \"Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.2.0\n---\n\n{{MANAGER_TEXT}}\n")
/// Hermes 0.22.0's copy (agent/turn_failure_copy.py), word for word.
private let hermesCopy = "This conversation has grown too long for gpt-6.1-sol to read, and Hermes couldn't shrink it enough automatically. Start a new session with /new (your history is kept), or try /compress once more. Switching to a model with a bigger context window also works."

/// One scripted answer per chat turn, in order.
private enum ScriptedTurn {
    case reply(String), overflow(String, code: String? = nil), stepsThenOverflow(String), status(Int)
    var reply: ChatParityServer.Reply {
        switch self {
        case .reply(let text): return .sse([("assistant.delta", ["delta": text]), ("assistant.completed", ["content": text, "completed": true]), ("run.completed", ["completed": true])])
        case .overflow(let text, let code):
            var failed: [String: Any] = ["content": text, "completed": false, "partial": true, "failed": true]
            if let code { failed["failure_reason"] = code }
            return .sse([("assistant.completed", failed), ("run.failed", ["completed": false, "partial": true])])
        case .stepsThenOverflow(let text):
            return .sse([("tool.started", ["tool_name": "terminal", "tool_call_id": "c1"]), ("tool.completed", ["tool_name": "terminal", "tool_call_id": "c1"]),
                         ("assistant.completed", ["content": text, "completed": false, "partial": true, "failed": true]), ("run.failed", ["completed": false])])
        case .status(let code): return .json(code, ["error": ["message": "Service unavailable"]])
        }
    }
}

/// Jarvis (manager, `grok-jarvis`) already talking in session `s-main`; the server answers chat turns from `script`.
@MainActor private func scriptedStore(_ script: [ScriptedTurn]) -> (AppStore, Bot, String) {
    let counter = LockedTrace()
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            counter.add("turn"); let index = counter.read().count - 1
            return (index < script.count ? script[index] : .reply("extra")).reply
        }
        if path == "/api/sessions", request.httpMethod == "POST" { return .json(201, ["session": ["id": body?["id"] as? String ?? "s-new"]]) }
        if request.httpMethod == "DELETE" { return .json(200, ["deleted": true]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "k"]), defaults: isolatedDefaults())
    store.managerTemplateOverride = "\(marker) you are {{MANAGER}} ({{MANAGER_ENV}})"
    store.skillLibraryOverride = [skill]
    store.setupRetrySleep = { _ in }
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true; jarvis.hermesSessionID = "s-main"
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis, host)
}

private func streams(_ host: String) -> [(session: String, input: String)] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { request in
        let session = request.path.replacingOccurrences(of: "/api/sessions/", with: "").replacingOccurrences(of: "/chat/stream", with: "")
        let input = (request.body?["input"] as? String) ?? ((request.body?["input"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "")
        return (session.removingPercentEncoding ?? session, input)
    }
}

private func installedBlock(_ version: String) -> String {
    "Installed.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[{\"name\":\"swarmhub-manager\",\"version\":\"\(version)\"}]}\n```"
}

/// No row the user can see repeats Hermes' advice to type a session command.
@MainActor private func noSlashAdvice(_ bot: Bot) -> Bool {
    !bot.messages.contains { $0.content.contains("/new") || $0.content.contains("/compress") }
}

// MARK: Installs

@Test @MainActor func anInstallRunsInAThrowawaySessionNeverTheMainOne() async throws {
    let (store, jarvis, host) = scriptedStore([.reply(installedBlock("1.2.0"))])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.installedSkills["swarmhub-manager"] != nil }
    let sent = streams(host)
    #expect(sent.count == 1)
    let setup = try #require(sent.first?.session)
    #expect(setup != "s-main" && setup.contains("agentapp_setup_"))
    #expect(jarvis.hermesSessionID == "s-main")
    // The throwaway session was created for the turn and deleted after it.
    let requests = ChatParityServer.requests(host)
    #expect(requests.contains { $0.method == "POST" && $0.path == "/api/sessions" && $0.body?["id"] as? String == setup })
    #expect(requests.contains { $0.method == "DELETE" && ($0.path.removingPercentEncoding ?? $0.path) == "/api/sessions/\(setup)" })
    // The install's rows stay visible in the manager's chat but are never history of its own conversation.
    #expect(jarvis.messages.filter { $0.metadata[ContextKey.setup] == "1" }.count == 2)
    let probe = ChatMessage(role: .assistant, content: "")
    #expect(store.chatHistory(jarvis, excluding: probe).isEmpty)
}

@Test @MainActor func anInstallThatCouldNotReachTheBoxIsRetriedInAFreshSession() async throws {
    let (store, jarvis, host) = scriptedStore([.status(503), .reply(installedBlock("1.2.0"))])
    #expect(store.installSkills(for: jarvis))
    // The retries happen inside the one turn: it ends only after the attempt that reached the box.
    try await waitUntil { !store.anyTurnRunning }
    let sent = streams(host).map(\.session)
    #expect(sent.count == 2 && Set(sent).count == 2 && !sent.contains("s-main"))
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.2.0"])
    #expect(!jarvis.messages.contains { $0.content.contains("Service unavailable") })
}

@Test @MainActor func retryingAnInstallRowStillSendsThatMessage() async throws {
    let (store, jarvis, _) = scriptedStore([.reply(installedBlock("1.2.0"))])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning }
    // Retry rebuilds history up to the row it retries: a setup row is history for that one request.
    let trigger = try #require(jarvis.messages.first { $0.role == .user })
    let history = store.chatHistory(jarvis, upTo: trigger, excluding: ChatMessage(role: .assistant, content: ""))
    #expect(history.count == 1 && history.last?.content == trigger.outgoingText)
}

// MARK: Overflow in the user's conversation

@Test @MainActor func anOverflowIsCompactedThenContinuedInANewSessionAndResent() async throws {
    let (store, jarvis, host) = scriptedStore([.overflow(hermesCopy), .overflow(hermesCopy), .reply("Here you go.")])
    #expect(store.send(text: "Summarise my week"))
    try await waitUntil { !store.anyTurnRunning }
    let sent = streams(host)
    #expect(sent.map(\.input) == ["Summarise my week", "Summarise my week", "Summarise my week"])
    #expect(sent.count == 3 && sent.prefix(2).map(\.session) == ["s-main", "s-main"] && sent.last?.session != "s-main")
    #expect(jarvis.hermesSessionID == sent.last?.session && jarvis.hermesSessionID?.hasPrefix("agentapp_\(jarvis.id.uuidString.lowercased())_") == true)
    let reply = try #require(jarvis.messages.last { $0.role == .assistant })
    #expect(reply.content == "Here you go." && reply.turnState == .finished)
    #expect(jarvis.messages.contains { $0.content == TurnErrorCopy.newSession && $0.metadata[ContextKey.boundary] == "1" })
    #expect(noSlashAdvice(jarvis) && store.errorMessage == nil)
    // The user's message is still there, once, above the new-session line's turn.
    #expect(jarvis.messages.filter { $0.role == .user }.map(\.content) == ["Summarise my week"])
}

@Test @MainActor func aCompactionThatWorksKeepsTheSession() async throws {
    let (store, jarvis, host) = scriptedStore([.overflow(hermesCopy), .reply("Done.")])
    #expect(store.send(text: "Next step?"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(streams(host).map(\.session) == ["s-main", "s-main"])
    #expect(jarvis.hermesSessionID == "s-main")
    #expect(jarvis.messages.contains { $0.content == TurnErrorCopy.compacted })
    #expect(jarvis.messages.last { $0.role == .assistant }?.content == "Done.")
    #expect(noSlashAdvice(jarvis) && store.errorMessage == nil)
}

@Test @MainActor func overflowIsRecognisedWhenHermesChangesItsWording() async throws {
    // New wording, no code; then no recognisable wording at all, but the machine code.
    let reworded = "Your chat history no longer fits in gpt-7's context window. Use /compress to shrink it."
    let (store, jarvis, host) = scriptedStore([.overflow(reworded), .overflow("Hermes stopped this turn (v9).", code: "context_overflow"), .reply("ok")])
    #expect(store.send(text: "hello"))
    try await waitUntil { !store.anyTurnRunning }
    let sent = streams(host)
    #expect(sent.count == 3 && sent.last?.session != "s-main")
    #expect(jarvis.messages.last { $0.role == .assistant }?.content == "ok")
    #expect(noSlashAdvice(jarvis))
}

@Test @MainActor func anOrdinaryFailureIsNotTreatedAsOverflow() async throws {
    let (store, jarvis, host) = scriptedStore([.overflow("Rate limit reached: too many tokens per minute.")])
    #expect(store.send(text: "hello"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(streams(host).count == 1 && jarvis.hermesSessionID == "s-main")
}

@Test @MainActor func anOverflowThatPersistsEndsWithAPlainLineNotHermesAdvice() async throws {
    let (store, jarvis, host) = scriptedStore([.overflow(hermesCopy), .overflow(hermesCopy), .overflow(hermesCopy)])
    #expect(store.send(text: "a very long paste"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(streams(host).count == 3)
    let reply = try #require(jarvis.messages.last { $0.role == .assistant })
    #expect(reply.content.isEmpty && reply.turnState == .incomplete)
    #expect(jarvis.messages.contains { $0.content == "Jarvis: \(TurnErrorCopy.tooLong)" })
    #expect(noSlashAdvice(jarvis))
    #expect(store.errorMessage == TurnErrorCopy.tooLong)
}

@Test @MainActor func aReplyWhoseStepsRanIsNeverResent() async throws {
    let (store, jarvis, host) = scriptedStore([.stepsThenOverflow(hermesCopy), .reply("never sent")])
    #expect(store.send(text: "deploy it"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(streams(host).count == 1)
    #expect(jarvis.hermesSessionID != "s-main")
    #expect(jarvis.messages.contains { $0.content == TurnErrorCopy.newSessionNotSent && $0.metadata[ContextKey.boundary] == "1" })
    #expect(jarvis.messages.contains { $0.content == "Jarvis: \(TurnErrorCopy.stoppedTooLong)" })
    #expect(noSlashAdvice(jarvis))
}

@Test func overflowDetectionUsesCodesAndLooseText() {
    #expect(ContextOverflow.matches(hermesCopy))
    #expect(ContextOverflow.matches("Request exceeds the context limit of this model"))
    #expect(!ContextOverflow.matches("Rate limit: too many tokens per min"))
    #expect(!ContextOverflow.matches("The model took too long to answer."))
    #expect(ContextOverflow.hasCode(["failure_reason": "context_overflow"]))
    #expect(ContextOverflow.hasCode(["error": ["code": "context_length_exceeded"]]))
    #expect(ContextOverflow.hasCode(["compression_exhausted": true]))
    #expect(!ContextOverflow.hasCode(["failure_reason": "rate_limit"]))
    #expect(ContextOverflow.isOverflow(.error(BackendError.http(413, "Payload too large"))))
    #expect(ContextOverflow.isOverflow(.failedByBox(ContextOverflow.tag + "whatever")))
    #expect(!ContextOverflow.isOverflow(.error(URLError(.timedOut))))
}
