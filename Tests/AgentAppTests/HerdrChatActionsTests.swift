import Foundation
import Testing
@testable import AgentApp

@Test func publishedCardsFollowTheTurnAndRetainTheirSource() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let rows = try decoder.decode([HerdrClient.Item].self, from: Data(#"[{"id":20,"kind":"artifact","detail":"old.pdf"},{"id":21,"kind":"task"},{"id":22,"kind":"page","detail":"Report","page_id":8,"page_revision":2},{"id":23,"kind":"artifact","detail":"data.csv"}]"#.utf8))
    var follower = HerdrTurnFollower(after: 20)
    follower.take(rows: rows)
    follower.take(rows: rows)
    let results = HerdrReplyResults(serverID: "original", items: follower.drain().compactMap { if case .published(let item) = $0 { return item }; return nil })
    #expect(results.items.map(\.id) == [22, 23])
    #expect(results.items.first?.pageID == 8 && results.items.first?.revision == 2)
    #expect(results.items.last?.kind == .file)
    let message = ChatMessage(role: .assistant, content: "Finished")
    message.publishedResults = results
    #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)).publishedResults == results)
}

@Test func nativeApprovalTargetsOnlyTheLiveSessionAndSendsOneChoice() async throws {
    let http = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/approvals":
            var pending: [[String: Any]] = []
            for (id, created) in [(1, 4), (2, 5)] {
                pending.append(["id": id, "created_ms": created, "address": "t1", "agent": "bot", "core": "c",
                                "provider": "Codex", "tool": "Read", "cwd": "/work", "arguments": "{}", "expires_ms": Int64.max / 2])
            }
            return (200, ["pending": pending])
        case "/api/workspace":
            return (200, ["core": "c", "templates": [], "agents": [["name": "bot", "created_ms": 5, "address": "t1", "state": "live"]]])
        case "/api/approvals/2": return (202, ["id": 2])
        default: return (404, ["error": "unexpected path"])
        }
    }
    let client = HerdrClient(baseURL: URL(string: "http://\(http.host)")!, token: "fixture", session: http.session)
    let approvals = try await client.approvals(for: "bot")
    #expect(approvals.map(\.id) == [2])
    try await client.decide(try #require(approvals.first), .deny)
    let post = try #require(MockHTTPProtocol.recorded(http.host).last)
    #expect(post.httpMethod == "POST" && post.bodyData == Data(#""deny""#.utf8))
    #expect(HerdrClient.Approval.visible("A\u{202E}B") == "A\\u{202E}B")
}

@Test func openCodeSwitchChecksTheCurrentSessionAndKeepsItsHistory() async throws {
    let http = MockHTTPProtocol.serve { request in
        guard request.url?.path == "/api/agents/t1/8/model" else { return (404, [:]) }
        if request.httpMethod == "GET" { return (200, ["current": "a/old", "default_model": "a/default"]) }
        guard let data = request.bodyData, let change = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              change["expected_current"] as? String == "a/old", change["expected_default"] as? String == "a/default",
              change["expected_core"] as? String == "c", let selection = change["change"] as? [String: String] else { return (400, [:]) }
        if selection["id"] == "a/conflict" { return (409, ["error": "Session is busy."]) }
        return (200, ["current": selection["id"] ?? "a/default", "default_model": "a/default"])
    }
    let client = HerdrClient(baseURL: URL(string: "http://\(http.host)")!, token: "fixture", session: http.session)
    let ref = HerdrClient.AgentRef(address: "t1", createdMs: 8)
    #expect(try await client.selectModel("a/new", for: ref, core: "c").effective == "a/new")
    #expect(try await client.selectModel(nil, for: ref, core: "c").effective == "a/default")
    await #expect(throws: HerdrClient.Failure.http(409, "Session is busy.")) { try await client.selectModel("a/conflict", for: ref, core: "c") }
    #expect(MockHTTPProtocol.recorded(http.host).map(\.httpMethod) == ["GET","POST","GET","POST","GET","POST"])
}
