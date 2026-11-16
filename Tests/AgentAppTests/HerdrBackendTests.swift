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
