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

@Test func herdrBotsHaveNoServerSessions() async throws {
    let id = UUID()
    let backend = HerdrBackend(client: HerdrClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "t"), botName: "Ada", botID: id, template: "")
    #expect(backend.kind == .herdr && backend.template == nil && !BackendKind.herdr.hasServerSessions)
    #expect(backend.agentName == "ada-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))
    #expect(try await backend.sessionTransport() == nil)
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
