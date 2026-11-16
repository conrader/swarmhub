import Foundation
import Testing
@testable import AgentApp

@Test func herdrAddressesAreLocalRootsOnly() {
    #expect(HerdrClient.validatedBaseURL("http://127.0.0.1:8787/")?.absoluteString == "http://127.0.0.1:8787")
    #expect(HerdrClient.validatedBaseURL(" https://localhost:9000 ")?.absoluteString == "https://localhost:9000")
    for bad in ["127.0.0.1:8787", "http://host/path", "ftp://host", "http://host?x=1", ""] { #expect(HerdrClient.validatedBaseURL(bad) == nil, "\(bad)") }
}

/// The bridge accepts 1–32 of `a-z 0-9 . - _`; the id suffix keeps a renamed bot on the same agent.
@Test func herdrAgentNamesFitTheBridge() {
    #expect(HerdrClient.agentName(for: "Ada Lovelace!", suffix: "1A2B3C4D5E") == "ada-lovelace-1a2b3c")
    #expect(HerdrClient.agentName(for: "Zażółć", suffix: "ABCDEF12") == "za-abcdef")
    #expect(HerdrClient.agentName(for: "!!!", suffix: "abcdef12") == "agent-abcdef")
    let long = HerdrClient.agentName(for: String(repeating: "word ", count: 20), suffix: "abcdef12")
    #expect(long.count <= 32 && long.hasSuffix("-abcdef") && !long.contains("--"))
    #expect(HerdrClient.suffix(of: "ada-lovelace-1a2b3c") == HerdrClient.suffix(of: "renamed-1a2b3c"))
}

/// Claude Code's and Codex's tool calls show with the chat's own step words; a start is reported once.
@Test func herdrToolCallsBecomeActivitySteps() {
    let running = HerdrClient.ToolCall(seq: 7, tool: "Bash", detail: "cargo test", finished: false, failed: false)
    #expect(HerdrBackend.toolEvents(running, isNew: true) == [ToolEvent(phase: .started, name: "bash", preview: "cargo test", callID: "herdr-7")])
    #expect(HerdrBackend.toolEvents(running, isNew: false).isEmpty)
    let failed = HerdrClient.ToolCall(seq: 7, tool: "Bash", detail: nil, finished: true, failed: true)
    #expect(HerdrBackend.toolEvents(failed, isNew: false) == [ToolEvent(phase: .failed, name: "bash", callID: "herdr-7")])
    #expect(HerdrBackend.toolEvents(failed, isNew: true).map(\.phase) == [.started, .failed])
    #expect(["apply_patch", "Edit", "Read", "WebSearch", "mcp__x__y"].map(HerdrBackend.toolName) == ["edit_file", "edit_file", "read_file", "web_search", "mcp__x__y"])
    #expect(ActivityCopy.label(HerdrBackend.toolName("Bash")) == "Running a command" && ActivityCopy.label(HerdrBackend.toolName("apply_patch")) == "Editing a file")
}

/// Starter bots begin on the first model the server offers; the app names none itself.
@Test @MainActor func herdrStarterModelIsTheServersFirst() {
    let first = HerdrClient.Template.Model(id: "first-model", label: nil), second = HerdrClient.Template.Model(id: "second-model", label: nil)
    #expect(AppStore.starterModel(offered: [first, second]) == "first-model")
    #expect(AppStore.starterModel(offered: []) == nil)
}

/// What a bot runs on is shown by the server's names: "no choice" resolves to the agent program new bots use and to
/// the first model the server offers, and the running agent's model is the one its session was launched with.
@MainActor @Test func aHerdrBotsRuntimeAndModelAreNamedNeverVague() throws {
    let one = HerdrClient.Template(name: "tpl-one", description: nil, error: nil, runtime: .init(harness: "Agent One", provider: nil, model: nil), modelAgent: "one")
    let two = HerdrClient.Template(name: "tpl-two", description: nil, error: nil, runtime: .init(harness: "Agent Two", provider: nil, model: nil))
    let offered = [HerdrClient.Template.Model(id: "m-a", label: "Model A"), HerdrClient.Template.Model(id: "m-b", label: "Model B")]
    let plain = HerdrAgentReading(templates: [one, two], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered)
    #expect(plain.runtimeLine == "Agent One · tpl-one (default)" && plain.modelLine == "Model A (default)" && plain.short == "Model A" && plain.runningLine == nil && plain.pendingLine == nil)
    #expect(plain.summary == "Agent program: Agent One · tpl-one (default). Model: Model A (default).")
    #expect(plain.model?.id == HerdrClient.defaultModel(offered: offered) && AppStore.starterModel(offered: offered) == "m-a", "the model shown is the one a start sends, by the rule starter bots use")
    let own = HerdrAgentReading(templates: [one, two], ownTemplate: "tpl-one", sharedTemplate: "tpl-two", ownModel: "m-b", offered: offered)
    #expect(own.runtimeLine == "Agent One · tpl-one" && own.modelLine == "Model B", "its own choices carry no (default)")
    let listless = HerdrAgentReading(templates: [one, two], ownTemplate: nil, sharedTemplate: "tpl-two", ownModel: "m-b", offered: [])
    #expect(listless.runtimeLine == "Agent Two · tpl-two (default)" && listless.modelLine == "Picked by the agent program" && listless.short == nil, "no list: the agent program picks, and no model is named")
    #expect(HerdrAgentReading(templates: [one], ownTemplate: "gone", sharedTemplate: nil, ownModel: nil, offered: []).runtimeLine == "No agent program this server can start")
    #expect(HerdrAgentReading.defaultLabel(shared: "tpl-two", in: [one, two]) == "Agent Two · tpl-two (default)" && HerdrAgentReading.defaultLabel(shared: nil, in: [one, two]) == "Agent One · tpl-one (default)" && HerdrAgentReading.defaultLabel(shared: nil, in: []) == nil)

    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let agent = try decoder.decode(HerdrClient.Agent.self, from: Data(#"{"address":"t9","created_ms":77,"name":"x-abc123","state":"live","template":"tpl-one","status":null}"#.utf8))
    let older = try decoder.decode(HerdrClient.Agent.self, from: Data(#"{"address":"t8","created_ms":70,"name":"x-abc123","state":"live","template":"tpl-one","status":null}"#.utf8))
    let profiles = try decoder.decode([HerdrClient.Profile].self, from: Data("""
    [{"id":1,"runtime_name":"x-abc123","sessions":[{"core":"c","address":"t9","created_ms":77,"template":"tpl-one","runtime":{"harness":"Agent One","provider":null,"model":"m-b","model_id":"m-b"}},
                                                  {"core":"c","address":"t8","created_ms":70,"template":"tpl-one","runtime":{"harness":"Agent One","provider":null,"model":null}}]},
     {"id":2,"runtime_name":"an-older-bridge-without-sessions"}]
    """.utf8))
    let running = HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered, agent: agent, profiles: profiles)
    #expect(running.running == .model(id: "m-b", label: "Model B") && running.short == "Model B" && running.runningLine == "The agent running now was started on Model B.")
    #expect(running.pendingLine == "Model A applies after “Start a fresh agent”.", "another model is chosen than the one running: it says when it applies")
    let same = HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: "m-b", offered: offered, agent: agent, profiles: profiles)
    #expect(same.pendingLine == nil && same.summary == "Agent program: Agent One · tpl-one (default). Model: Model B. Running on Model B now.")
    let unstated = HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered, agent: older, profiles: profiles)
    #expect(unstated.running == .unstated && unstated.short == nil && unstated.runningLine?.contains("started without a model") == true && unstated.pendingLine == "Model A applies after “Start a fresh agent”.", "an agent started without a model is not given one by guess")
    #expect(HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered, agent: agent, profiles: []).running == .unknown)
}
