import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One running session as the bridge sends it on `GET /api/agents/{address}/{created_ms}/events` (Server-Sent
/// Events): a `snapshot` first, then whatever changes. A client follows a turn on this one connection instead of
/// asking for the history, the reply so far and the agent's status again and again. The polling routes read the same
/// state, so a row has the same `id` and a tool call the same `seq` on either, and a client can change from one to
/// the other in the middle of a turn. Foundation only, and the same reader on Apple's Foundation and on Linux.
enum HerdrEvent: Sendable, Equatable {
    /// The reply so far: `id` names the message being written, so text of another message is never appended to it.
    struct Draft: Decodable, Sendable, Equatable { let id: String; var text: String }

    /// Always first. With `after` in the request, `rows` holds only rows saved after that one.
    struct Snapshot: Sendable, Equatable {
        var core: String?
        var agent: HerdrClient.Agent?
        var rows: [HerdrClient.Item] = []
        var draft: Draft?
        var tools: [HerdrClient.ToolCall] = []
        var helpers: HerdrClient.Helpers?
    }

    case snapshot(Snapshot)
    /// A row was saved or changed: it replaces the row with the same id.
    case history(HerdrClient.Item)
    /// The reply so far starts, is replaced, or (nil) is gone.
    case draft(Draft?)
    /// The reply so far gained `text`; `offset` is the UTF-8 length of what the reader should already hold.
    case draftAppend(id: String, offset: Int, text: String)
    /// A tool call starts, and again with the same `seq` when it ends.
    case tool(HerdrClient.ToolCall)
    case agent(HerdrClient.Agent)
    /// The session's running helpers. A null listing means the workspace could not supply one.
    case helpers(HerdrClient.Helpers?)
    /// The agent's program ended ("ended") or Core no longer has the terminal ("gone"). The server closes after it.
    case end(reason: String)
    /// Nothing changed for 15 seconds; the connection is alive.
    case heartbeat

    /// One event from its name and JSON. An event this build does not know, or cannot read, is nil and skipped.
    static func decode(name: String, data: String) -> HerdrEvent? {
        struct Appended: Decodable { let id: String; let offset: Int; let text: String }
        struct Ended: Decodable { let reason: String? }
        struct Wire: Decodable {
            struct Page: Decodable { let items: [HerdrClient.Item] }
            let core: String?; let agent: HerdrClient.Agent?; let history: Page?; let draft: Draft?; let tools: [HerdrClient.ToolCall]?; let helpers: HerdrClient.Helpers?
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let bytes = Data(data.utf8)
        func read<T: Decodable>(_ type: T.Type) -> T? { try? decoder.decode(type, from: bytes) }
        switch name {
        case "snapshot":
            return read(Wire.self).map { .snapshot(Snapshot(core: $0.core, agent: $0.agent, rows: $0.history?.items ?? [], draft: $0.draft, tools: $0.tools ?? [], helpers: $0.helpers)) }
        case "history": return read(HerdrClient.Item.self).map(HerdrEvent.history)
        case "draft": return data.trimmingCharacters(in: .whitespaces) == "null" ? .draft(nil) : read(Draft.self).map { .draft($0) }
        case "draft_append": return read(Appended.self).map { .draftAppend(id: $0.id, offset: $0.offset, text: $0.text) }
        case "tool": return read(HerdrClient.ToolCall.self).map(HerdrEvent.tool)
        case "agent": return read(HerdrClient.Agent.self).map(HerdrEvent.agent)
        case "helpers": return data.trimmingCharacters(in: .whitespaces) == "null" ? .helpers(nil) : read(HerdrClient.Helpers.self).map { .helpers($0) }
        case "end": return .end(reason: read(Ended.self)?.reason ?? "ended")
        default: return nil
        }
    }
}

/// Server-Sent Events from bytes as they arrive, whatever way the network cuts them: a chunk may end in the middle
/// of a line or of a character. A blank line ends an event; a line that starts with ":" is a comment (the bridge's
/// heartbeat).
struct HerdrSSEParser: Sendable {
    enum Frame: Sendable, Equatable { case event(name: String, data: String), comment(String) }
    private var pending = Data(), name = "", data: [String] = []

    mutating func feed(_ chunk: Data) -> [Frame] {
        pending.append(chunk)
        var frames: [Frame] = []
        while let end = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<end]
            pending = Data(pending[pending.index(after: end)...])
            if line.last == 0x0D { line = line.dropLast() }
            let text = String(decoding: line, as: UTF8.self)
            if text.isEmpty {
                if !data.isEmpty || !name.isEmpty { frames.append(.event(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))) }
                name = ""; data = []
            } else if text.hasPrefix(":") {
                frames.append(.comment(String(text.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                var value = parts.count > 1 ? String(parts[1]) : ""
                if value.hasPrefix(" ") { value.removeFirst() }
                switch parts[0] { case "event": name = value; case "data": data.append(value); default: break }
            }
        }
        return frames
    }
}

/// Reads one response body as it arrives and hands on every chunk at once. `URLSession.bytes(for:)` would do on
/// Apple's Foundation, but swift-corelibs-foundation on Linux has none, so both use this delegate.
final class HerdrByteStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let validateResponse: @Sendable (URLResponse) throws -> Void
    private let idleTimeout: TimeInterval?
    private let idleTimer: DispatchSourceTimer?
    private var idleDeadline: DispatchTime = .distantFuture

    /// The bytes of `request`'s answer, chunk by chunk. A status other than 2xx throws `HerdrClient.Failure`; the
    /// stream ends when the server closes. The request's own timeout is how long nothing may arrive before the read
    /// fails: it counts silence, not the length of the answer.
    static func open(_ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral,
                     resourceTimeout: TimeInterval = 24 * 3600,
                     idleTimeout: TimeInterval? = nil,
                     validateResponse: @escaping @Sendable (URLResponse) throws -> Void = validateHerdrResponse) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = resourceTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // The timer and URLSession callbacks share a serial queue so only received bytes extend the deadline.
            let queue = DispatchQueue(label: "HerdrByteStream")
            let callbacks = OperationQueue()
            callbacks.maxConcurrentOperationCount = 1
            callbacks.underlyingQueue = queue
            let timer = idleTimeout.map { _ in DispatchSource.makeTimerSource(queue: queue) }
            let reader = HerdrByteStream(continuation, idleTimeout: idleTimeout, idleTimer: timer, validateResponse: validateResponse)
            let session = URLSession(configuration: TestRunGuard.guarded(configuration), delegate: reader, delegateQueue: callbacks)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in timer?.cancel(); task.cancel(); session.invalidateAndCancel() }
            timer?.setEventHandler { [weak reader] in
                guard let reader, DispatchTime.now() >= reader.idleDeadline else { return }
                reader.continuation.finish(throwing: URLError(.timedOut))
            }
            reader.resetIdleDeadline()
            timer?.activate()
            task.resume()
        }
    }

    private init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation,
                 idleTimeout: TimeInterval?, idleTimer: DispatchSourceTimer?,
                 validateResponse: @escaping @Sendable (URLResponse) throws -> Void) {
        self.continuation = continuation
        self.idleTimeout = idleTimeout
        self.idleTimer = idleTimer
        self.validateResponse = validateResponse
    }

    private func resetIdleDeadline() {
        guard let idleTimeout else { return }
        idleDeadline = .now() + idleTimeout
        idleTimer?.schedule(deadline: idleDeadline)
    }

    private static func validateHerdrResponse(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HerdrClient.failure(status: code, body: Data()) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try validateResponse(response)
            completionHandler(.allow)
        } catch {
            continuation.finish(throwing: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        resetIdleDeadline()
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }
}

extension HerdrClient {
    /// How long a stream may be silent before it counts as broken.
    static let streamIdle: TimeInterval = 40

    /// The session's events from now on. `after`: the newest saved row the caller already has, so the snapshot
    /// brings only later rows. Throws `Failure.http(404, …)` from a bridge without the route (or for a terminal Core
    /// no longer has) and `http(429, …)` when the bridge has its 48 streams open; either way the caller reads the
    /// session with the polling routes instead. The stream finishing without `.end` means the connection broke.
    func events(of agent: AgentRef, after: Int? = nil) -> AsyncThrowingStream<HerdrEvent, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try client.request("/api/agents/\(agent.address)/\(agent.createdMs)/events" + (after.map { "?after=\($0)" } ?? ""), method: "GET", body: nil)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Silence for longer than two of the bridge's 15 s heartbeats means the connection is dead.
                    request.timeoutInterval = Self.streamIdle
                    request = try await client.prepared(request)
                    var parser = HerdrSSEParser()
                    for try await chunk in (client.byteSource ?? { HerdrByteStream.open($0) })(request) {
                        for frame in parser.feed(chunk) {
                            switch frame {
                            case .comment: continuation.yield(.heartbeat)
                            case .event(let name, let data): if let event = HerdrEvent.decode(name: name, data: data) { continuation.yield(event) }
                            }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension HerdrClient.HelperLog {
    /// Takes one event of the helper's own session into the log. False when a `draft_append` does not fit what the
    /// log holds: the reader then connects again and gets the reply so far whole.
    mutating func apply(_ event: HerdrEvent, draftID: inout String?) -> Bool {
        func place(_ row: HerdrClient.Item) {
            func put(_ row: HerdrClient.Item, in rows: inout [HerdrClient.Item]) {
                if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row } else { rows.append(row); rows.sort { $0.id < $1.id } }
            }
            if row.kind == "task" { put(row, in: &tasks) } else if row.kind == "reply" { put(row, in: &replies) }
        }
        func note(_ call: HerdrClient.ToolCall) {
            if let index = tools.firstIndex(where: { $0.seq == call.seq }) { tools[index] = call } else { tools.append(call); tools.sort { $0.seq < $1.seq } }
        }
        switch event {
        case .snapshot(let snapshot):
            snapshot.rows.forEach(place); snapshot.tools.forEach(note)
            draft = snapshot.draft?.text; draftID = snapshot.draft?.id
        case .history(let row): place(row)
        case .draft(let now): draft = now?.text; draftID = now?.id
        case .draftAppend(let id, let offset, let text):
            guard id == draftID, (draft ?? "").utf8.count == offset else { return false }
            draft = (draft ?? "") + text
        case .tool(let call): note(call)
        case .agent, .helpers, .end, .heartbeat: break
        }
        return true
    }
}
