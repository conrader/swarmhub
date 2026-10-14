import Foundation
import Testing
@testable import SwarmHubCore

private struct StubReply: Sendable { let status: Int; let body: String }
private final class StubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (URLRequest) throws -> StubReply] = [:]
    func add(_ id: String, handler: @escaping @Sendable (URLRequest) throws -> StubReply) { lock.lock(); defer { lock.unlock() }; handlers[id] = handler }
    func reply(_ request: URLRequest) throws -> StubReply {
        lock.lock(); let handler = handlers[request.value(forHTTPHeaderField: "X-Test-Session") ?? ""]; lock.unlock()
        guard let handler else { throw CoreError.invalidResponse }; return try handler(request)
    }
}
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let registry = StubRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.registry.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func client(profile: String = "research", handler: @escaping @Sendable (URLRequest) throws -> StubReply) throws -> HermesClient {
    let id = UUID().uuidString
    StubProtocol.registry.add(id, handler: handler)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]; config.httpAdditionalHeaders = ["X-Test-Session": id]
    return HermesClient(address: try ConnectionAddress("https://agents.example.com", profile: profile), key: "synthetic-key", session: URLSession(configuration: config))
}

@Test func profileProbeCannotSilentlyUseDefaultAgent() async throws {
    let backend = try client { request in
        #expect(request.url?.path == "/p/research/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
        return StubReply(status: 200, body: "{\"data\":[{\"id\":\"default\"}]}")
    }
    await #expect(throws: (any Error).self) { try await backend.verify() }
}

@Test func capabilityProbeHonorsFalseFlagsAndLegacy404() async throws {
    let backend = try client { _ in StubReply(status: 200, body: "{\"features\":{\"session_chat_streaming\":true,\"run_stop\":false}}") }
    let flags = try await backend.capabilities()
    #expect(flags.sessions); #expect(!flags.stop)
    let legacy = try client { _ in StubReply(status: 404, body: "{}") }
    #expect(try await legacy.capabilities().features.isEmpty)
}

@Test func historyIsPagedAndOffsetBasedIDsStayStable() async throws {
    let backend = try client { request in
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "order", value: "oldest")))
        let offset = query.first { $0.name == "offset" }!.value!
        if offset == "0" {
            let row = "{\"role\":\"assistant\",\"content\":\"same text\"}"
            return StubReply(status: 200, body: "{\"data\":[" + Array(repeating: row, count: 500).joined(separator: ",") + "]}")
        }
        #expect(offset == "500")
        return StubReply(status: 200, body: "{\"data\":[{\"id\":501,\"role\":\"user\",\"content\":\"last\"}]}")
    }
    let messages = try await backend.messages(sessionID: "session-1")
    #expect(messages.count == 501)
    #expect(Set(messages.map(\.id)).count == 501)
    #expect(messages.last?.id == "501")
}

@Test func serverErrorNeverEchoesResponseCredentials() async throws {
    let backend = try client { _ in StubReply(status: 401, body: "{\"error\":\"synthetic-key\"}") }
    do { _ = try await backend.sessions(); Issue.record("Expected authorization failure") }
    catch { #expect(!error.localizedDescription.contains("synthetic-key")) }
}

@Test func resourceIDsCannotChangeEndpoint() async throws {
    let backend = try client { _ in Issue.record("Invalid IDs must not make a request"); return StubReply(status: 500, body: "{}") }
    await #expect(throws: CoreError.invalidIdentifier) { try await backend.messages(sessionID: "../../other") }
}

@Test func emptyStreamDoesNotClaimCompletion() async throws {
    let backend = try client { request in
        if request.url!.path.hasSuffix("capabilities") { return StubReply(status: 200, body: "{\"features\":{\"session_chat_streaming\":true}}") }
        return StubReply(status: 200, body: "event: assistant.delta\ndata: {\"delta\":\"partial\"}\n\n")
    }
    await #expect(throws: CoreError.interruptedStream) { for try await _ in backend.stream(sessionID: "session-1", text: "sample") {} }
}
