import Foundation
@testable import AgentApp

// What the handoff checks share: synthetic archive lines, and a bridge that keeps every agent's saved rows and
// records each POST with its text and attached files. No name, text or secret here belongs to anyone.

/// One archive line, numbered `seq`, a minute after the one before it.
func handoffLine(_ seq: Int64, _ role: String, _ text: String, hidden: Bool = false, channel: String = "chat", author: String? = nil, to: String? = nil) -> ArchivedMessage {
    ArchivedMessage(id: "m\(seq)", seq: seq, role: role, author: author, text: text,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(seq) * 60), hidden: hidden, channel: channel, to: to)
}

/// `exchanges` questions and answers, each message about `bytes` long and ending in words that name it ("question 7 end").
func handoffConversation(exchanges: Int, bytes: Int = 40) -> [ArchivedMessage] {
    var lines: [ArchivedMessage] = []
    for index in 1...exchanges {
        let filler = String(repeating: "word ", count: max(0, (bytes - 20) / 5))
        lines.append(handoffLine(Int64(index * 2 - 1), "user", "\(filler) question \(index) end"))
        lines.append(handoffLine(Int64(index * 2), "assistant", "\(filler) answer \(index) end", author: "Ada"))
    }
    return lines
}

/// A saved summary of `plan`'s older part, as a summary agent would have left it.
func handoffSummary(_ text: String, of plan: GrokHandoff.Plan) -> GrokHandoffCache {
    GrokHandoffCache(summary: text, from: plan.older.first?.seq ?? 0, through: plan.older.last?.seq ?? 0, messages: plan.older.count,
                     template: "", model: "", madeAt: Date(timeIntervalSince1970: 1_700_000_000))
}

/// A bridge with any number of agents. A launch or a message that carries a task is saved as a `task` row of that
/// agent's session and, unless `answers` returns nil for it, answered at once with a `reply` row.
final class HandoffBridge: @unchecked Sendable {
    struct Sent: Sendable, Equatable {
        /// `launch`, `launch-with-files`, `message`, `message-with-files` or `end`.
        let route: String
        let agent: String
        let text: String
        /// Attached files, by name.
        var files: [String: String] = [:]
        var workspaceID: String? = nil
    }

    private let lock = NSLock()
    private var agents: [[String: Any]] = [], rows: [String: [[String: Any]]] = [:], posts: [Sent] = [], started = 0, historyReads = 0
    private var refusals: [String] = [], waiting: [String] = []
    /// What the server says it can do, the status every agent reports, and what an agent replies to a task.
    /// Set before the first request.
    var attachments = true, launchAttachments = true
    var agentState: String? = nil
    var answers: @Sendable (String) -> String? = { _ in "ok" }
    /// The agent names this server refuses to start.
    var refusesLaunch: @Sendable (String) -> Bool = { _ in false }
    /// A reply that is saved only at the third read of a session's rows: an agent that was still working when the
    /// first read was made.
    var lateReply: String? = nil
    /// Like the real server, a read of a session's rows returns only its newest `pageSize`; nil returns them all.
    var pageSize: Int? = nil
    /// The server refuses every request that carries files (422).
    var refusesFiles = false
    /// The tasks an agent takes but does not answer until `release`.
    var holds: @Sendable (String) -> Bool = { _ in false }

    var sent: [Sent] { lock.withLock { posts } }
    /// What the server refused, in order: the agent's name for a launch, the route for a request with files.
    var refused: [String] { lock.withLock { refusals } }

    /// The agents that hold a task back answer it now.
    func release(_ reply: String) {
        lock.withLock {
            for key in waiting { rows[key, default: []].append(row("reply", reply, in: key)) }
            waiting = []
        }
    }
    var liveNames: [String] { lock.withLock { agents.compactMap { $0["name"] as? String } } }

    func client() -> HerdrClient {
        let (host, session) = MockHTTPProtocol.serve { [self] in answer($0) }
        var client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t", session: session)
        client.following = .polling; client.pollInterval = .milliseconds(2); client.agentCheckInterval = .milliseconds(5)
        return client
    }

    /// A running agent with these saved rows, oldest first, as (`task` or `reply`, text). `warm`: started ahead of
    /// time and not written to yet.
    func seed(agent name: String, template: String = "tpl-one", warm: Bool = false, rows seeded: [(kind: String, text: String)] = []) {
        lock.withLock {
            let key = add(name: name, template: template, warm: warm)
            for entry in seeded { rows[key, default: []].append(row(entry.kind, entry.text, in: key)) }
        }
    }

    /// The message part and the files of a request: a JSON body, or a multipart one as `HerdrClient` writes it.
    static func parts(_ request: URLRequest) -> (message: [String: Any], files: [String: String]) {
        let data = request.bodyData ?? Data()
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let marker = type.range(of: "boundary=") else {
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], [:])
        }
        let boundary = "--" + String(type[marker.upperBound...])
        var message: [String: Any] = [:]
        var files: [String: String] = [:]
        for part in String(decoding: data, as: UTF8.self).components(separatedBy: boundary) {
            guard let gap = part.range(of: "\r\n\r\n") else { continue }
            let head = String(part[..<gap.lowerBound])
            var content = String(part[gap.upperBound...])
            // "\r\n" is one character.
            if content.hasSuffix("\r\n") { content = String(content.dropLast()) }
            if head.contains("name=\"message\"") {
                message = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
            } else if let from = head.range(of: "filename=\""), let to = head[from.upperBound...].firstIndex(of: "\"") {
                files[String(head[from.upperBound..<to])] = content
            }
        }
        return (message, files)
    }

    // MARK: The routes (all under the lock)

    private func add(name: String, template: Any, warm: Bool) -> String {
        started += 1
        var agent: [String: Any] = ["address": "t\(started)", "created_ms": started, "name": name, "state": "live", "template": template, "ready": true, "warm": warm]
        if let agentState { agent["status"] = ["state": agentState] }
        agents.append(agent)
        let key = "t\(started)/\(started)"
        rows[key] = []
        return key
    }

    /// `address/created` of an agent, as the routes name its session.
    private static func key(_ agent: [String: Any]) -> String { "\(agent["address"] as? String ?? "")/\(agent["created_ms"] as? Int ?? 0)" }

    private func row(_ kind: String, _ text: String, in key: String) -> [String: Any] {
        ["id": (rows[key]?.count ?? 0) + 1, "kind": kind, "state": kind == "task" ? "sent" : "received", "text": text]
    }

    /// A task reaches the agent: saved, answered, and the agent is no longer unused.
    private func take(_ task: String, in key: String) {
        rows[key, default: []].append(row("task", task, in: key))
        if holds(task) { waiting.append(key) } else if let reply = answers(task) { rows[key, default: []].append(row("reply", reply, in: key)) }
        if let index = agents.firstIndex(where: { Self.key($0) == key }) { agents[index]["warm"] = false }
    }

    private func name(of key: String) -> String {
        agents.first(where: { Self.key($0) == key })?["name"] as? String ?? ""
    }

    func answer(_ request: URLRequest) -> (Int, Any) {
        let method = request.httpMethod ?? "GET", path = request.url?.path ?? ""
        let pieces = path.split(separator: "/").map(String.init)
        return lock.withLock { () -> (Int, Any) in
            if method == "GET", path == "/api/workspace" {
                let template: [String: Any] = ["name": "tpl-one", "description": "", "error": NSNull(), "runtime": ["harness": "Agent One", "provider": NSNull(), "model": NSNull()]]
                let workspace: [String: Any] = ["core": "c", "version": "1", "attachments": attachments, "launch_attachments": launchAttachments,
                                                "bot_workspaces": true, "agents": agents, "templates": [template]]
                return (200, workspace)
            }
            if method == "GET", path == "/api/profiles" { return (200, [Any]()) }
            if method == "POST", refusesFiles, path.hasSuffix("/with-files") {
                refusals.append(path.hasSuffix("/messages/with-files") ? "message-with-files" : "launch-with-files")
                return (422, ["error": "This bot needs a workspace folder for attachments."])
            }
            if method == "POST", path == "/api/agents" || path == "/api/agents/with-files" {
                let (message, files) = Self.parts(request)
                let name = message["name"] as? String ?? ""
                if refusesLaunch(name) { refusals.append(name); return (500, ["error": "The agent could not be started."]) }
                let key = add(name: name, template: message["template"] ?? "", warm: message["warm"] as? Bool == true)
                let task = message["task"] as? String
                posts.append(Sent(route: files.isEmpty ? "launch" : "launch-with-files", agent: name, text: task ?? "", files: files, workspaceID: message["workspace_id"] as? String))
                if let task { take(task, in: key) }
                return (201, agents[agents.count - 1])
            }
            if method == "GET", pieces.count >= 5, pieces[1] == "history" {
                if pieces.count == 6 { return (200, ["draft": NSNull(), "tools": [Any]()]) }
                let key = "\(pieces[3])/\(pieces[4])"
                historyReads += 1
                if historyReads == 3, let late = lateReply { rows[key, default: []].append(row("reply", late, in: key)) }
                let all: [[String: Any]] = rows[key] ?? []
                let saved: [[String: Any]] = pageSize.map { Array(all.suffix($0)) } ?? all
                return (200, ["items": saved])
            }
            if method == "POST", pieces.count >= 5, pieces[1] == "agents" {
                let key = "\(pieces[2])/\(pieces[3])", action = pieces[4...].joined(separator: "/")
                let agent = name(of: key)
                if action == "end" {
                    posts.append(Sent(route: "end", agent: agent, text: ""))
                    agents.removeAll { Self.key($0) == key }
                    return (200, [String: Any]())
                }
                if action == "messages" || action == "messages/with-files" {
                    let (message, files) = Self.parts(request)
                    let text = message["text"] as? String ?? ""
                    posts.append(Sent(route: files.isEmpty ? "message" : "message-with-files", agent: agent, text: text, files: files))
                    take(text, in: key)
                    return (200, ["queued": false])
                }
            }
            return (404, ["error": "no route"])
        }
    }
}

/// A store whose one server is `bridge`, with one bot on it. With `lines`, the bot is one that was imported: it has
/// an archive of them.
@MainActor func handoffStore(_ bridge: HandoffBridge, lines: [ArchivedMessage] = [], botID: UUID = UUID(), storeURL: URL = temporaryStore()) throws -> (store: AppStore, bot: Bot) {
    let store = AppStore(storeURL: storeURL, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let client = bridge.client()
    store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Test", kind: .address, address: client.baseURL.absoluteString), token: "t")
    store.herdrClientSetup = { made in
        made.session = client.session; made.following = .polling; made.pollInterval = client.pollInterval; made.agentCheckInterval = client.agentCheckInterval
    }
    let bot = Bot(id: botID, name: "Ada", backend: .herdr)
    store.bots = [bot]; store.selectedBot = bot
    if !lines.isEmpty {
        bot.grokSourceID = "source-one"
        bot.grokHistoryCount = try store.grokHistory.merge(lines, sourceID: "source-one", for: bot.id)
    }
    return (store, bot)
}
