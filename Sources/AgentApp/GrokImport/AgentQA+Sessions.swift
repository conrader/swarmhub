import Foundation

extension AgentQA {
    /// The interactive window and the unattended hunt use the same private workspace responses.
    func installSessionSamples() throws {
        guard let bot = store.bots.first(where: { $0.name == "Mira" }),
              let patch = store.bots.first(where: { $0.name == "Patch" }) else { throw QAError("Sample bots are missing.") }
        let server = HerdrServer(id: "qa", name: "Sample workspace", kind: .address, address: "http://workspace.invalid")
        store.saveHerdrServers([server])
        store.setHerdrToken("sample", for: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionSampleProtocol.self]
        let session = URLSession(configuration: config)
        store.herdrClientSetup = { $0.session = session }
        store.herdrHelpers[bot.id] = .init(core: "sample", parent: .init(address: "t1", createdMs: 1), helpers: [],
                                           codexThreads: SessionSampleProtocol.children)
        store.herdrHelpers[patch.id] = .init(core: "sample", parent: .init(address: "t2", createdMs: 2), helpers: [],
                                             codexThreads: SessionSampleProtocol.reviewThreads)
        if let atlas = store.bots.first(where: { $0.name == "Atlas" }) {
            let root = HerdrHelperParent(botID: atlas.id)
            let helper = SessionSampleProtocol.reviewer
            store.herdrHelpers[root] = .init(core: "sample", parent: .init(address: "t3", createdMs: 3), helpers: [helper])
            store.herdrHelpers[root.children(of: helper.ref, core: "sample")] = .init(core: "sample", parent: helper.ref, helpers: [],
                                                                                      codexThreads: SessionSampleProtocol.reviewThreads)
        }
    }

    func visibleChildren(_ bot: Bot) -> [SidebarSessionItem] {
        guard store.sessionsExpanded(for: bot) else { return [] }
        return store.sidebarRoots(for: bot).flatMap { store.sessionRows(under: $0, for: bot) }
    }

    var terminalID: String {
        guard let target = store.inspectorTerminal?.target else { return "" }
        if case .agent(let ref) = target.id { return ref.address + "/" + String(ref.createdMs) }
        return target.id.child?.thread ?? ""
    }

    func terminalTranscript() async throws -> String {
        guard store.showInfo, let request = store.inspectorTerminal, let target = request.target else {
            throw QAError("Open a child terminal first.")
        }
        let client = try store.herdrClient(for: request.server)
        if case .agent(let ref) = target.id {
            let roster = try await client.workspace()
            guard roster.core == target.core, roster.agents.contains(where: { $0.ref == ref && $0.isLive }) else {
                throw QAError("This terminal session has ended.")
            }
            return try await client.screen(of: ref)
        }
        guard let child = target.id.child else { throw QAError("Open a child terminal first.") }
        return try await client.threadActivity(child.runtime, owner: child.owner, core: child.core, thread: child.thread).transcript
    }

    func sessionAction(_ action: String, bot: Bot, target: String?, provider: String?) throws {
        if provider != nil && target == nil { throw QAError("Specify a session id with its provider.") }
        if let target {
            let matches = visibleChildren(bot).filter {
                $0.selection.helperID == target && (provider == nil || $0.qaProvider == provider)
            }
            guard matches.count <= 1 else { throw QAError("More than one visible session has this id. Specify its provider.") }
            guard let row = matches.first else { throw QAError("Choose a visible session id under " + bot.name + ".") }
            switch action {
            case "fold", "unfold":
                switch row {
                case .workspace(let child) where child.hasChildren:
                    store.setHelperBranchFolded(action == "fold", branch: child.branch, for: bot)
                case .native(let child, _, _) where child.hasChildren:
                    store.setNativeSessionFolded(action == "fold", target: child.id, for: bot)
                default: throw QAError("This session has no child sessions.")
                }
            case "terminal":
                guard let terminal = row.terminal else { throw QAError("This terminal session has ended.") }
                store.previewInInspector(.init(server: store.herdrServer(for: bot), target: terminal))
            case "child":
                store.open(bot, helper: row.selection)
            default: throw QAError("This action applies to the open session.")
            }
            return
        }
        switch action {
        case "child": throw QAError("Choose a visible session id under " + bot.name + ".")
        case "unfold", "fold":
            guard !store.sidebarRoots(for: bot).isEmpty else { throw QAError("This bot has no sessions.") }
            store.setSessionsExpanded(action == "unfold", for: bot)
        case "terminal", "parent", "steer":
            guard let selection = store.openHerdrHelper, selection.botID == bot.id else { throw QAError("Open a child first.") }
            if action == "terminal" {
                let target: LiveTerminal
                if let native = selection.native {
                    target = LiveTerminal(thread: native.thread, owner: native.owner, core: native.core)
                } else if let list = store.herdrHelpers[selection.parent],
                          let helper = list.sidebarSessions.first(where: { $0.id == selection.helperID && $0.isLive }) {
                    target = LiveTerminal(agent: helper.ref, title: helper.name, core: list.core)
                } else { throw QAError("This terminal session has ended.") }
                store.previewInInspector(.init(server: store.herdrServer(for: bot), target: target))
            } else if action == "steer" {
                guard store.beginHelperSteering(selection, of: bot) else { throw QAError("This helper is unavailable.") }
            } else {
                store.open(store.backDestination(for: selection, of: bot), of: bot)
            }
        default: throw QAError("Unknown session action.")
        }
    }
}

extension SidebarSessionItem {
    var qaProvider: String { selection.native?.thread.provider.rawValue ?? "workspace" }

    var qaState: [String: Any] {
        let name: String, state: String, children: Bool, folded: Bool
        switch self {
        case .workspace(let row):
            name = row.helper.name
            state = row.helper.showingAnswer ? "answered" : row.helper.status?.state ?? row.helper.state
            children = row.hasChildren
            folded = row.folded
        case .native(let row, _, _):
            name = row.thread.name
            state = row.thread.state
            children = row.hasChildren
            folded = row.folded
        }
        return ["id": selection.helperID, "name": name, "state": state, "provider": qaProvider, "depth": depth,
                "hasChildren": children, "expanded": children && !folded]
    }
}

/// Intercept every request on this private URLSession, including unknown paths.
private final class SessionSampleProtocol: URLProtocol, @unchecked Sendable {
    static let started = Int64(Date.now.timeIntervalSince1970 * 1000) - 72000
    static let reviewer = HerdrClient.Helper(address: "helper", createdMs: 4, name: "Reviewer", task: "Check the release",
                                             state: "live", status: .init(state: "working"))
    static let children: [HerdrClient.NativeThread] = [
        .init(id: "tests", parent: "main", name: "tests", model: "Sol", createdMs: started, state: "working",
              task: "Check the CSV reader.", reply: ""),
        .init(id: "rename", parent: "main", name: "rename", model: "Sol", createdMs: started, completedMs: started + 41000,
              state: "answered", task: "Review renamed call sites.", reply: "Updated 14 call sites.")
    ]
    static let reviewThreads: [HerdrClient.NativeThread] = [
        .init(id: "review", parent: "main", name: "review", model: "Sol", createdMs: started, state: "working",
              task: "Review the changes.", reply: ""),
        .init(id: "citations", parent: "review", name: "citations", model: "Sol", createdMs: started, state: "working",
              task: "Check references in the review.", reply: "")
    ]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let child = Self.children.first { url.path == "/api/agents/t1/1/codex-threads/" + $0.id }
            ?? Self.reviewThreads.first { url.path == "/api/agents/t2/2/codex-threads/" + $0.id }
        let nested = Self.reviewThreads.first { url.path == "/api/agents/helper/4/codex-threads/" + $0.id }
        let accepted = url.host == "workspace.invalid" && url.query == "core=sample" && request.httpMethod == "GET"
        var body = Data()
        if accepted, let child = child ?? nested {
            let command = Self.reviewThreads.contains(child) ? "git status --short" : child.isWorking ? "swift test --filter CSVReaderTests" : "git diff --stat"
            let output = Self.reviewThreads.contains(child) ? child.task : child.isWorking ? "Running CSVReaderTests" : "14 call sites updated"
            let detail: [String: Any] = ["task": child.task, "reply": child.reply,
                "steps": [["text": command, "state": child.isWorking ? "inProgress" : "completed"]],
                "terminal": ["command": command, "output": output]]
            body = (try? JSONSerialization.data(withJSONObject: ["details": detail, "transcript": "$ " + command + "\n" + output, "state": child.state])) ?? Data()
        }
        if request.httpMethod == "GET", url.host == "workspace.invalid" {
            switch url.path {
            case "/api/workspace":
                body = Data(#"{"core":"sample","agents":[{"address":"helper","created_ms":4,"name":"Reviewer","state":"live","status":{"state":"working"}}],"templates":[]}"#.utf8)
            case "/api/agents/helper/4/output":
                body = Data(#"{"text":"Checking the release notes"}"#.utf8)
            default: break
            }
        }
        if let response = HTTPURLResponse(url: url, statusCode: body.isEmpty ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
