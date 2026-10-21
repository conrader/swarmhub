import Foundation
import Testing
@testable import AgentApp

@Test func installInstructionsBudgetCountsJSONEscapingAndEveryPromptLayer() throws {
    let limit = SkillInstallPayloadError.instructionsByteBudget
    let overhead = try JSONSerialization.data(withJSONObject: ["instructions": ""]).count
    let exact = AgentRequest(sessionID: "test", systemPrompt: String(repeating: "x", count: limit - overhead), messages: [])
    try SkillInstallPayloadError.validate(exact, policy: nil)
    let over = AgentRequest(sessionID: "test", systemPrompt: exact.systemPrompt + "x", messages: [])
    #expect(throws: SkillInstallPayloadError.self) { try SkillInstallPayloadError.validate(over, policy: nil) }
    // Raw UTF-8 fits, but quotes and newlines escape to two bytes on the actual wire.
    let escaped = AgentRequest(sessionID: "test", systemPrompt: String(repeating: "\"\n", count: limit / 3), messages: [])
    #expect(escaped.effectiveSystemPrompt.utf8.count < limit)
    #expect(throws: SkillInstallPayloadError.self) { try SkillInstallPayloadError.validate(escaped, policy: nil) }
    let layered = AgentRequest(sessionID: "test", systemPrompt: "Persona\n\nYour heartbeat: hourly.", messages: [],
                               managementText: String(repeating: "x", count: limit - 100))
    try SkillInstallPayloadError.validate(layered, policy: nil)
    #expect(throws: SkillInstallPayloadError.self) { try SkillInstallPayloadError.validate(layered, policy: String(repeating: "p", count: 500)) }
    let unicode = AgentRequest(sessionID: "test", systemPrompt: String(repeating: "🦋", count: limit / 4), messages: [])
    #expect(throws: SkillInstallPayloadError.self) { try SkillInstallPayloadError.validate(unicode, policy: nil) }
}

@Test @MainActor func providerPayloadErrorsNeverIncreaseSkillInstallBackoff() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Manager", backend: .hermes, hermesProfile: "default"); bot.canManageBots = true
    store.bots = [bot]
    let skill = try #require(store.skills(for: bot).first)
    store.noteSkillInstallFailure(skill.name, version: skill.version.description,
                                  variant: SkillLibrary.variant(of: skill, codingOrder: store.codingOrder(for: bot)), reason: "Earlier write failed.", on: bot)
    let before = bot.skillInstallFailures
    let errors: [TurnEnd] = [
        .error(BackendError.http(400, "Invalid 'instructions': string too long. Expected max 1048576, got 2802969.")),
        .error(BackendError.http(400, "context_length_exceeded")),
        .error(BackendError.http(413, "Request Entity Too Large")),
        .failedByBox("HTTP 400: maximum context length exceeded"),
        .error(BackendError.unavailable("HTTP 400: request-too-large")),
        .error(SkillInstallPayloadError(bytes: 800_000))
    ]
    for end in errors {
        store.noteSkillInstallChecks([(bot, [skill])], manager: bot)
        store.finishSkillInstallChecks(manager: bot, reply: ChatMessage(role: .assistant, content: ""), end: end)
        #expect(bot.skillInstallFailures == before)
        #expect(store.skillInstallResults[bot.id]?.status == .clientPayloadError)
    }
    #expect(!SkillInstallPayloadError.isPayloadError(.error(BackendError.http(400, "invalid model"))))
    #expect(!SkillInstallPayloadError.isPayloadError(.error(BackendError.http(503, "server overloaded"))))
    #expect(!SkillInstallPayloadError.isPayloadError(.completed))
}

@Test func peerEnablementRequiresBothSuccessfulEnableAndAnEnabledListEntry() {
    func receipt(exit: Int = 0, listExit: Int = 0, output: String = "", list: String) -> PeerPluginEnablement.Receipt {
        .init(profile: "grok-jarvis", enable_exit: exit, list_exit: listExit, enable_output: output, list_output: list)
    }
    let enabled = "swarmhub-peer  enabled"
    #expect(receipt(list: enabled).verified)
    #expect(!receipt(exit: 1, list: enabled).verified)
    #expect(!receipt(listExit: 1, list: enabled).verified)
    for list in ["swarmhub-peer disabled", "swarmhub-peer not enabled", "other-plugin enabled", "", "swarmhub-peer enabled: false"] {
        #expect(receipt(list: list).result.status == .peerEnableUnverified)
    }
    let pm = "PermissionError: [Errno 13] Permission denied: '/home/hermes/.hermes/installs/id/environments/gen/workspace/pyproject.toml'"
    #expect(receipt(exit: 1, output: pm, list: "swarmhub-peer disabled").result.status == .peerEnableBlocked)
    #expect(receipt(output: "Hermes PM dependency-sync failed", list: "").result.status == .peerEnableBlocked)
}

@Test @MainActor func aMatchedPMEnableFailureRecordsOperatorStatusWithoutSkillBackoff() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); bot.canManageBots = true
    store.bots = [bot]
    let skill = try #require(store.skills(for: bot).first { $0.name == "swarmhub-messages" })
    store.noteSkillInstallChecks([(bot, [skill])], manager: bot)
    let hermes = HermesBackend(baseURL: URL(string: "http://127.0.0.1")!, apiKey: "")
    let command = PeerPluginEnablement.command(profile: "grok-jarvis")
    store.notePeerEnableTool(hermes.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "enable", "args": ["command": command]]), manager: bot)
    let receipt: [String: Any] = ["profile": "grok-jarvis", "enable_exit": 1, "list_exit": 0,
        "enable_output": "PermissionError: permission denied: environments/gen/workspace/pyproject.toml", "list_output": "swarmhub-peer disabled"]
    let stdout = PeerPluginEnablement.marker + String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self)
    let result: [String: Any] = ["tool_name": "terminal", "tool_call_id": "enable", "result": ["exit_code": 0, "output": stdout]]
    store.notePeerEnableTool(hermes.nativeTool("tool.completed", result), manager: bot)
    let reply = ChatMessage(role: .assistant, content: """
    Skills written.
    ```swarmhub
    {"op":"skills_installed","bot":"grok-jarvis","skills":[{"name":"swarmhub-messages","version":"\(skill.version)"}]}
    ```
    """)
    store.finishSkillInstallChecks(manager: bot, reply: reply, end: .completed)
    #expect(bot.installedSkills[skill.name] == skill.version.description && bot.skillInstallFailures.isEmpty)
    #expect(store.skillInstallResults[bot.id]?.status == .peerEnableBlocked)
    #expect(bot.messages.last?.content.contains("needs box operator") == true)
    #expect(bot.messages.last?.content.contains("Held delivery is inactive") == true)
    // Old servers can report the same failure without a tool result or a skills_installed block.
    store.noteSkillInstallChecks([(bot, store.missingMessagingSkills(for: bot) + [skill])], manager: bot)
    let legacyReply = ChatMessage(role: .assistant, content: "Installed and verified the skills; peer-plugin activation was blocked by filesystem permissions.")
    store.finishSkillInstallChecks(manager: bot, reply: legacyReply, end: .completed)
    #expect(bot.skillInstallFailures.isEmpty && store.skillInstallResults[bot.id]?.status == .peerEnableBlocked)
    // An unrelated call cannot provide a receipt.
    var call = PeerPluginEnablement.Call()
    call.consume(.init(phase: .started, name: "terminal", callID: "other", command: "echo fake"), profiles: ["grok-jarvis"])
    call.consume(.init(phase: .completed, name: "terminal", callID: "other", result: stdout), profiles: ["grok-jarvis"])
    #expect(call.receipt == nil)
}
