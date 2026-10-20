import Foundation
import Testing
import SwarmHubCore
@testable import AgentApp

@MainActor @Test func defaultPolicyCoversExistingBotsAndRefreshesSettingsWithoutEditingPersona() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    let original = Bot(name: "Scout", description: "Research", persona: "My custom persona", backend: .hermes, hermesSessionID: "existing")
    let bot = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(original))
    store.bots = [jarvis, bot]; store.heartbeatTimeZone = TimeZone(identifier: "Europe/Warsaw")!
    store.quietHours = QuietHours(start: 23 * 60, end: 7 * 60)
    let backend = try #require(try store.backend(for: bot) as? HermesBackend)
    let first = try #require(backend.defaultInstructions)
    #expect(first.contains("Research") && first.contains("Jarvis (grok-jarvis)"))
    #expect(first.contains("Europe\\/Warsaw") || first.contains("Europe/Warsaw"))
    #expect(first.contains("23:00–07:00") && first.contains("Ask me"))
    bot.name = "Researcher"; store.orientationCoordinatorChoice = .none
    let refreshed = try #require(try store.backend(for: bot) as? HermesBackend)
    #expect(refreshed.defaultInstructions?.contains("Researcher") == true)
    #expect(refreshed.defaultInstructions?.contains("Jarvis (grok-jarvis)") == false)
    #expect(bot.persona == "My custom persona" && bot.hermesSessionID == "existing")
}

@Test func hermesPolicyTravelsOnCreationAndEveryExistingNativeOrLegacyTurn() async throws {
    for native in [true, false] {
        let (host, unconfigured) = ChatParityServer.serve(features: ["session_chat_streaming": native]) { request, _ in
            if request.httpMethod == "POST", request.url!.path == "/api/sessions" { return .json(200, ["session": ["id": "existing"]]) }
            if request.url!.path.hasSuffix("/chat/stream") { return .sse([("run.completed", [:])]) }
            return .init(body: Data("data: [DONE]\n\n".utf8))
        }
        var backend = unconfigured
        backend.defaultInstructions = try BotSystemPrompt.render(BotPromptContext(name: "Scout"))
        if native { _ = try await backend.createSession(title: "Scout", systemPrompt: "custom persona", id: "existing") }
        let request = AgentRequest(sessionID: "existing", systemPrompt: "custom persona", messages: [("user", "Hello")], managementText: "manager recipe")
        for _ in 0..<2 { for try await _ in try await backend.send(request) {} }
        let posts = ChatParityServer.requests(host).filter { $0.method == "POST" }
        #expect(posts.count == (native ? 3 : 2))
        for post in posts {
            let body = try #require(post.body)
            let messages = body["messages"] as? [[String: Any]]
            let text = try #require(body["system_prompt"] as? String ?? body["instructions"] as? String ?? messages?.first?["content"] as? String)
            #expect(text.contains("# Swarm Hub default behavior") && text.contains("custom persona"))
            if body["system_prompt"] == nil { #expect(text.contains("manager recipe")) }
            #expect(text.components(separatedBy: "# Swarm Hub default behavior").count == 2)
        }
    }
}

@MainActor @Test func openClawGetsSharedPolicyOnEveryTurnWithoutLeakingPersonaOrAddingRPCFields() async throws {
    let (store, bot, _, _) = clawStore()
    bot.persona = "DO-NOT-SEND-HERMES-PERSONA"
    let backend = try #require(try store.backend(for: bot) as? OpenClawBackend)
    #expect(backend.defaultInstructions?.contains("Alpha") == true)
    // Use the existing fake transport, configured with that factory-rendered policy.
    var (wireBackend, fake, _) = clawBackend()
    wireBackend.defaultInstructions = backend.defaultInstructions
    fake.handlers["chat.send"] = ackingSend(before: [chatEvent("final", seq: 1, ["message": assistant("ok")])])
    let request = AgentRequest(sessionID: "agent:agent-alpha:s1", systemPrompt: bot.persona, messages: [("user", "Hello")], managementText: "manager recipe")
    for _ in 0..<2 { _ = try await collect(wireBackend.send(request)) }
    let schema = try ParamKeys()
    for params in fake.requestsFor("chat.send") {
        let message = try #require(params["message"]?.string)
        #expect(message.hasPrefix(BotSystemPrompt.envelopeOpen) && message.contains("manager recipe"))
        #expect(!message.contains(bot.persona))
        #expect(schema.problems("chat.send", params).isEmpty)
        #expect(ManagerEnvelope.strip(BotSystemPrompt.stripEnvelope(message)) == "Hello")
        let history: GatewayJSON = ["messages": [["role": "user", "content": [["type": "text", "text": .string(message)]]]]]
        #expect(OpenClawHistory.rows(history).first?.content == "Hello")
    }
}
