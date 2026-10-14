import Foundation
import Testing
@testable import SwarmHubCore

@Test func addressNormalizesAndScopesProfiles() throws {
    let address = try ConnectionAddress(" https://agents.example.com/p/research/v1/ ", profile: "research")
    #expect(address.baseURL.absoluteString == "https://agents.example.com")
    #expect(try address.endpoint("api/sessions", query: [.init(name: "limit", value: "100")]).absoluteString == "https://agents.example.com/p/research/api/sessions?limit=100")
}

@Test(arguments: ["http://agents.example.com", "https://key@agents.example.com", "https://agents.example.com?token=secret", "https://agents.example.com/#secret", "file:///tmp/server"])
func rejectsUnsafeAddresses(_ value: String) {
    #expect(throws: (any Error).self) { try ConnectionAddress(value) }
}

@Test func loopbackNeedsExplicitFixtureOptIn() throws {
    #expect(throws: CoreError.insecureAddress) { try ConnectionAddress("http://127.0.0.1:18000") }
    _ = try ConnectionAddress("http://127.0.0.1:18000", allowLoopbackHTTP: true)
    #expect(throws: CoreError.insecureAddress) { try ConnectionAddress("http://192.168.1.1", allowLoopbackHTTP: true) }
}

@Test(arguments: ["../default", "research/other", "x?token=y", "", "profile name"])
func profileCannotEscapeScope(_ profile: String) {
    #expect(throws: CoreError.invalidProfile) { try ConnectionAddress("https://agents.example.com", profile: profile) }
}

@Test func textSplittingRetainsUnicodeAndBounds() {
    let text = String(repeating: "🦊資料\n", count: 35_000)
    let parts = HermesContent.splitText(text)
    #expect(parts.allSatisfy { $0.unicodeScalars.count <= 60_000 })
    #expect(parts.joined(separator: "\n") == text)
    #expect(HermesContent.parts(text: "small") as? String == "small")
}

@Test func requestBodyFailsBeforeOversizedSend() throws {
    #expect(throws: CoreError.requestTooLarge) { try HermesContent.body(["input": "a large sample"], limit: 2) }
}

@Test func sseDispatchesMultilineDataAndPersistentID() throws {
    var decoder = SSEDecoder()
    #expect(try decoder.consume(": keepalive") == nil)
    #expect(try decoder.consume("id: 7") == nil)
    #expect(try decoder.consume("event: assistant.delta") == nil)
    #expect(try decoder.consume("data: {\"delta\":") == nil)
    #expect(try decoder.consume("data: \"hello\"}") == nil)
    let decoded = try decoder.consume("")
    let frame = try #require(decoded)
    #expect(frame.id == "7")
    #expect(try HermesClient.event(frame) == .delta("hello"))
}

@Test func cancelledRunIsNotCompletedAndDoneIsNotTerminal() throws {
    #expect(try HermesClient.event(SSEFrame(event: "run.cancelled", data: "{}", id: nil)) == .terminal(.cancelled))
    #expect(try HermesClient.event(SSEFrame(event: "message", data: "[DONE]", id: nil)) == nil)
    #expect(try HermesClient.event(SSEFrame(event: "run.failed", data: "{\"error\":\"private-key-value\"}", id: nil)) == .terminal(.failed))
}

@Test func byteDecoderPreservesBlankLinesAndSplitUTF8() throws {
    var decoder = SSEByteDecoder()
    var frames: [SSEFrame] = []
    let wire = "\u{FEFF}event: assistant.delta\r\ndata: {\"delta\":\"資料🦊\"}\r\n\r\nevent: run.completed\ndata: {}\n\n"
    for byte in wire.utf8 { if let frame = try decoder.consume(byte) { frames.append(frame) } }
    #expect(frames.count == 2)
    #expect(try HermesClient.event(frames[0]) == .delta("資料🦊"))
    #expect(try HermesClient.event(frames[1]) == .terminal(.completed))
}

@Test func approvalsNeedExactActionAndOfferedChoice() {
    let sample = ApprovalItem(runID: "run-1", requestID: "req-1", title: "Read notes", command: "cat notes.txt", choices: ["once", "deny"])
    #expect(sample.canApprove)
    #expect(!ApprovalItem(runID: "run-1", requestID: "req-1", title: "Hidden", command: "cat ***", choices: ["once"]).canApprove)
    #expect(!ApprovalItem(runID: "run-1", requestID: "req-1", title: "Display only", command: nil, choices: ["once"]).canApprove)
}

@Test func sqliteReopenRetainsDraftAndUncertainTurn() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("cache.sqlite")
    let first = try SQLiteRepository(url: url)
    let profile = AgentProfile(name: "Research", address: try ConnectionAddress("https://agents.example.com", profile: "research"))
    try await first.saveProfiles([profile])
    let turn = PendingTurn(sessionID: "session-1", input: "a sample task", output: "partial", runID: "run-1", state: .interrupted)
    try await first.saveCache(ChatCache(messages: [.init(id: "message-1", role: .assistant, text: "cached result")], draft: "unsent draft", turn: turn), agentID: profile.id)
    let second = try SQLiteRepository(url: url)
    #expect(try await second.profiles() == [profile])
    let cache = try await second.cache(agentID: profile.id)
    #expect(cache.draft == "unsent draft")
    #expect(cache.turn == turn)
    #expect(cache.messages.count == 1)
    try await second.remove(agentID: profile.id)
    #expect(try await second.profiles().isEmpty)
    #expect(try await second.cache(agentID: profile.id).messages.isEmpty)
}
