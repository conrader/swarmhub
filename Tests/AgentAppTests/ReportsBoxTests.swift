import Foundation
import Testing
@testable import AgentApp

// P36 store level with a synthetic box: a bot's `report` op makes a pending row, the manager's quiet listing turn (the
// P35 recipe, now with `reports`) brings the body, Send posts it and a quiet "Close reports" turn renames the file;
// Dismiss deletes it the same way. ChatParityServer answers the manager's turns by request; SwarmHubStub is SwarmHub.

private func block(_ json: String) -> String { "Done.\n```swarmhub\n\(json)\n```" }
private let fileJSON = #"{"id":"r1-aa","kind":"bug","title":"bot-msg timed out","body":"bot-msg --to cfo exited 124 twice.","source":"agent","bot":"cfo","bot_backend":"hermes","skill_versions":{"swarmhub-messages":"1.0.0"},"created_at":"2026-10-15T10:15:00Z"}"#
private let wishJSON = #"{"id":"r2-bb","kind":"feature","title":"Group mentions","body":"Let me @ a bot.","source":"agent","bot":"cfo","created_at":"2026-10-15T10:16:00Z"}"#

@MainActor private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

@Test @MainActor func reportOpListingSendAndCloseThroughTheManager() async throws {
    let (chat, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        let input = body?["input"] as? String ?? ""
        if request.url!.path == "/api/sessions" { return .json(200, ["session": ["id": "s-box"]]) }
        guard request.url!.path.hasSuffix("/chat/stream") else { return .json(404, ["error": "no route"]) }
        let instructions = body?["instructions"] as? String ?? ""
        let reply: String
        if input.hasPrefix("List every bot") {
            reply = block(#"{"op":"bots","list":[{"name":"grok-jarvis","has_key":true},{"name":"cfo","has_key":true}],"reports":[\#(fileJSON),\#(wishJSON)]}"#)
        } else {
            let sent = instructions.contains("for I in r1-aa;") ? #"["r1-aa"]"# : "[]", deleted = instructions.contains("for I in r2-bb;") ? #"["r2-bb"]"# : "[]"
            reply = block(#"{"op":"reports_closed","sent":\#(sent),"deleted":\#(deleted)}"#)
        }
        return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])])
    }
    let (_, swarmhub, session) = SwarmHubStub.serve { _, _ in (201, ["id": "17", "status": "received"]) }
    let keys = InMemoryKeyStore(["hermes": "k", "hermes.grok-jarvis": "m", "hermes.cfo": "c"])
    keys.setKey(#"{"accessToken":"tok-1","expiresAt":4102444800}"#, for: SwarmHubToken.account)
    let defaults = isolatedDefaults(); defaults.set("https://\(swarmhub)/swarmhub", forKey: SwarmHubService.baseURLKey)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: keys, defaults: defaults)
    store.reportsCenter.session = session
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
    let cfo = Bot(name: "Cfo", backend: .hermes, hermesProfile: "cfo")
    store.bots = [jarvis, cfo]
    let inbox = { store.reportsCenter.inbox }

    store.handleReportOps(ChatMessage(role: .assistant, content: block(#"{"op":"report","id":"r1-aa","kind":"bug","title":"bot-msg timed out"}"#)), from: cfo)
    #expect(inbox().report("r1-aa")?.hasBody == false && inbox().report("r1-aa")?.bot == "cfo")
    await waitFor { inbox().report("r1-aa")?.hasBody == true && inbox().report("r2-bb") != nil }
    let first = try #require(inbox().report("r1-aa"))
    #expect(first.body == "bot-msg --to cfo exited 124 twice." && first.skillVersions == ["swarmhub-messages": "1.0.0"] && store.reportBot(first) === cfo)
    #expect(inbox().pendingCount == 2 && cfo.messages.isEmpty && jarvis.messages.isEmpty, "quiet turns only")

    await store.sendReport("r1-aa")
    #expect(inbox().report("r1-aa")?.serverID == "17")
    let posted = try #require(SwarmHubStub.requests(swarmhub).first?.body)
    #expect(posted["bot"] as? String == "cfo" && posted["source"] as? String == "agent" && posted["skill_versions"] as? [String: String] == ["swarmhub-messages": "1.0.0"])
    await waitFor { inbox().report("r1-aa")?.boxFile == .closed }
    #expect(inbox().report("r1-aa")?.boxFile == .closed)

    store.dismissReport("r2-bb")
    await waitFor { inbox().report("r2-bb") == nil }
    #expect(inbox().reports.map(\.id) == ["r1-aa"])
    let turns = ChatParityServer.requests(chat).filter { $0.path.hasSuffix("/chat/stream") }.map { $0.body?["instructions"] as? String ?? "" }
    let close = turns.filter { $0.contains(#"mv "$I.json" "$I.sent""#) }
    #expect(close.count == 2 && close[0].contains("for I in r1-aa;") && close[1].contains("for I in r2-bb;"))
    #expect(turns.allSatisfy { !$0.contains("tok-1") }, "the SwarmHub token never reaches the box")
}
