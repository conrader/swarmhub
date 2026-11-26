import Foundation

extension AgentQA {
    /// The interactive window and the unattended hunt use the same private workspace responses.
    func installSessionSamples() throws {
        guard let bot = store.bots.first(where: { $0.name == "Mira" }) else { throw QAError("Mira is missing.") }
        let server = HerdrServer(id: "qa", name: "Sample workspace", kind: .address, address: "http://workspace.invalid")
        store.saveHerdrServers([server])
        store.setHerdrToken("sample", for: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionSampleProtocol.self]
        let session = URLSession(configuration: config)
        store.herdrClientSetup = { $0.session = session }
        store.herdrHelpers[bot.id] = .init(core: "sample", parent: .init(address: "t1", createdMs: 1), helpers: [],
                                           codexThreads: SessionSampleProtocol.children)
    }

    func visibleChildren(_ bot: Bot) -> [HerdrClient.NativeThread] {
        guard store.defaults.object(forKey: bot.sessionsExpandedKey) as? Bool != false else { return [] }
        return store.herdrHelpers[bot.id]?.nativeThreads ?? []
    }

    func terminalActivity() async throws -> HerdrClient.ThreadActivity {
        guard store.showInfo, let request = store.inspectorTerminal, let child = request.target?.id.child else {
            throw QAError("Open a child terminal first.")
        }
        return try await store.herdrClient(for: request.server).threadActivity(child.runtime, owner: child.owner, core: child.core, thread: child.thread)
    }

    func sessionAction(_ action: String, bot: Bot, target: String?) throws {
        switch action {
        case "unfold", "fold":
            guard store.herdrHelpers[bot.id]?.hasSidebarSessions == true else { throw QAError("This bot has no sessions.") }
            store.defaults.set(action == "unfold", forKey: bot.sessionsExpandedKey)
        case "child" where target != nil, "terminal" where target != nil:
            guard let list = store.herdrHelpers[bot.id], let child = visibleChildren(bot).first(where: { $0.id == target }) else {
                throw QAError("Choose a visible session id under " + bot.name + ".")
            }
            let server = store.herdrServer(for: bot)
            if action == "terminal" {
                store.previewInInspector(.init(server: server, target: LiveTerminal(thread: child, owner: list.parent, core: list.core)))
            } else {
                let native = HerdrHelperSelection.Native(thread: child, core: list.core, owner: list.parent, server: server)
                store.open(bot, helper: .init(botID: bot.id, helperID: child.id, native: native))
            }
        case "terminal", "parent", "steer":
            guard let selection = store.openHerdrHelper, let native = selection.native else { throw QAError("Open a child first.") }
            if action == "terminal" {
                let target = LiveTerminal(thread: native.thread, owner: native.owner, core: native.core)
                store.previewInInspector(.init(server: native.server, target: target))
            } else if action == "steer" {
                guard store.beginHelperSteering(selection, of: bot) else { throw QAError("This helper is unavailable.") }
            } else if !store.openHelperParent(selection, of: bot) { throw QAError("Could not open the parent chat.") }
        default: throw QAError("Unknown session action.")
        }
    }
}

/// Intercept every request on this private URLSession, including unknown paths.
private final class SessionSampleProtocol: URLProtocol, @unchecked Sendable {
    static let started = Int64(Date.now.timeIntervalSince1970 * 1000) - 72000
    static let children: [HerdrClient.NativeThread] = [
        .init(id: "tests", parent: "main", name: "tests", model: "Sol", createdMs: started, state: "working",
              task: "Check the CSV reader.", reply: ""),
        .init(id: "rename", parent: "main", name: "rename", model: "Sol", createdMs: started, completedMs: started + 41000,
              state: "answered", task: "Review renamed call sites.", reply: "Updated 14 call sites.")
    ]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let child = Self.children.first { url.path == "/api/agents/t1/1/codex-threads/" + $0.id }
        let accepted = url.host == "workspace.invalid" && url.query == "core=sample" && request.httpMethod == "GET"
        var body = Data()
        if accepted, let child {
            let command = child.isWorking ? "swift test --filter CSVReaderTests" : "git diff --stat"
            let output = child.isWorking ? "Running CSVReaderTests" : "14 call sites updated"
            let detail: [String: Any] = ["task": child.task, "reply": child.reply,
                "steps": [["text": command, "state": child.isWorking ? "inProgress" : "completed"]],
                "terminal": ["command": command, "output": output]]
            body = (try? JSONSerialization.data(withJSONObject: ["details": detail, "transcript": "$ " + command + "\n" + output, "state": child.state])) ?? Data()
        }
        if let response = HTTPURLResponse(url: url, statusCode: body.isEmpty ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
