import Foundation

/// P12: one turn. Subscribe to the session's events first, then `chat.send`; take `runId` from the ack and replay only
/// that run's buffered events (before the ack matched by session key, after it by run id). The stream ends on the
/// primary run's `final`, `aborted` or `error`. A dropped link is resumed from `chat.history`, never resent by hand.
extension OpenClawBackend {
    static let lostRun = "Connection lost; the run may still be running on the Gateway."

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let (connection, capabilities) = try await connected()
        try require(.chat, in: capabilities)
        let sessionKey = request.sessionID
        let typed = request.messages.last { $0.role == "user" }?.content ?? ""
        let text = request.managementText.map { ManagerEnvelope.wrap($0, around: typed) } ?? typed
        var params: [String: GatewayJSON] = ["sessionKey": .string(sessionKey), "agentId": .string(agentID), "message": .string(text),
                                            "idempotencyKey": .string(UUID().uuidString.lowercased())]
        if !request.images.isEmpty {
            try require(.attachments, in: capabilities)
            params["attachments"] = .array(try OpenClawAttachments.encode(request.images, summary: capabilities.summary))
        }
        let sendParams = GatewayJSON.object(params)
        try OpenClawAttachments.checkFrame(sendParams, summary: capabilities.summary)
        let (subscription, events) = await connection.subscribe(Self.matcher(sessionKey))
        let hub = hub, agentID = agentID
        return AsyncThrowingStream { continuation in
            let task = Task {
                var runId: String?
                defer {
                    let finishedRun = runId
                    Task { await connection.unsubscribe(subscription); if let finishedRun { await hub.ledger.finish(sessionKey: sessionKey, runId: finishedRun) } }
                }
                do {
                    let ack = try await call(connection, "chat.send", sendParams)
                    guard let id = ack["runId"]?.string else { throw BackendError.unavailable("The Gateway accepted the message but sent no run id.") }
                    runId = id
                    await hub.ledger.start(.init(sessionKey: sessionKey, agentId: agentID, runId: id))
                    if Task.isCancelled { // Stop came before the ack: the run exists now, so abort it
                        _ = try? await call(connection, "chat.abort", ["sessionKey": .string(sessionKey), "agentId": .string(agentID), "runId": .string(id)], timeout: Self.abortTimeout)
                        throw CancellationError()
                    }
                    var mapper = OpenClawRunMapper(sessionKey: sessionKey); mapper.setPrimary(id)
                    try await stream(events, into: &mapper, continuation)
                    while !mapper.isFinished, !Task.isCancelled {
                        try await resume(sessionKey: sessionKey, mapper: &mapper, continuation)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Chat events of this session and every agent event (agent events carry no session key; the run id sorts them).
    static func matcher(_ sessionKey: String) -> @Sendable (GatewayEvent) -> Bool {
        let key = sessionKey.lowercased()
        return { event in
            if event.event == "agent" { return true }
            return event.event == "chat" && event.payload["sessionKey"]?.string?.lowercased() == key
        }
    }

    private func stream(_ events: AsyncStream<GatewayEvent>, into mapper: inout OpenClawRunMapper, _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        for await event in events {
            for output in mapper.map(event) { continuation.yield(output) }
            if mapper.isFinished { return }
        }
        if Task.isCancelled { throw CancellationError() }
    }

    /// After a reconnect: subscribe on the new link, re-read `chat.history`; a run still active continues from
    /// `inFlightRun.text`; a finished one gives its final assistant message; anything else fails plainly.
    private func resume(sessionKey: String, mapper: inout OpenClawRunMapper, _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        guard let runId = mapper.primaryRunId else { throw BackendError.unavailable(Self.lostRun) }
        let connection: GatewayConnection
        do { connection = try await hub.connection(for: gateway) } catch { throw BackendError.unavailable(Self.lostRun) }
        let (subscription, events) = await connection.subscribe(Self.matcher(sessionKey))
        defer { Task { await connection.unsubscribe(subscription) } }
        let history: GatewayJSON
        do { history = try await historyPage(connection, sessionKey: sessionKey) } catch { throw BackendError.unavailable(Self.lostRun) }
        let info = history["sessionInfo"]
        let active = info?["activeRunIds"]?.strings.contains(runId) == true
            || (info?["activeRunIds"] == nil && info?["hasActiveRun"]?.bool == true && history["inFlightRun"]?["runId"]?.string == runId)
        if active {
            if let inFlight = history["inFlightRun"], inFlight["runId"]?.string == runId, let text = inFlight["text"]?.string {
                let before = mapper.text
                mapper.resume(from: text)
                if mapper.text != before { continuation.yield(mapper.text.hasPrefix(before) ? .token(String(mapper.text.dropFirst(before.count))) : .replace(mapper.text)) }
            }
            try await stream(events, into: &mapper, continuation)
            return
        }
        let rows = history["messages"]?.array ?? []
        guard let last = rows.last, last["role"]?.string == "assistant", let final = OpenClawText.visible(last) else { throw BackendError.unavailable(Self.lostRun) }
        if final != mapper.text { continuation.yield(.replace(final)) }
        continuation.yield(.completed)
        mapper.finishFromHistory()
    }

    /// `chat.history {sessionKey, agentId, limit: 200, maxChars: 20000}` (15 s).
    func historyPage(_ connection: GatewayConnection, sessionKey: String) async throws -> GatewayJSON {
        try await call(connection, "chat.history", ["sessionKey": .string(sessionKey), "agentId": .string(agentID), "limit": .int(Self.historyLimit),
                                                    "maxChars": .int(Self.historyMaxChars)], timeout: Self.historyTimeout)
    }

    /// `chat.send` with `queueMode:"steer"` and a fresh key; its run joins the active run's ignore set.
    func steer(sessionID: String, text: String) async throws {
        let (connection, capabilities) = try await connected()
        try require(.steer, in: capabilities)
        let ack = try await call(connection, "chat.send", ["sessionKey": .string(sessionID), "agentId": .string(agentID), "message": .string(text),
                                                           "idempotencyKey": .string(UUID().uuidString.lowercased()), "queueMode": "steer"], feature: .steer)
        if let runId = ack["runId"]?.string { await hub.ledger.ignore(runId, sessionKey: sessionID) }
    }
}

/// Images from `AttachmentEncoder` (data URLs) become `{type:"image", mimeType, fileName, content: <raw base64>}`, each
/// checked against `policy.attachments.maxImageBytes`, and the whole frame against `maxPayload`, before sending.
enum OpenClawAttachments {
    struct Refusal: LocalizedError, Equatable { let text: String; var errorDescription: String? { text } }

    static func encode(_ dataURLs: [String], summary: GatewaySummary) throws -> [GatewayJSON] {
        try dataURLs.enumerated().map { index, url in
            guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else {
                throw Refusal(text: "Image \(index + 1) is not an encoded image.")
            }
            let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<comma].dropLast(7))
            let content = String(url[url.index(after: comma)...])
            let bytes = Data(base64Encoded: content)?.count ?? (content.count * 3 / 4)
            let limit = summary.maxImageBytes ?? summary.maxAttachmentBytes
            if let limit, bytes > limit {
                throw Refusal(text: "Image \(index + 1) is \(OpenClawHub.megabytes(bytes)); this Gateway takes images up to \(OpenClawHub.megabytes(limit)).")
            }
            let ext = mime.split(separator: "/").last.map(String.init) ?? "png"
            return ["type": "image", "mimeType": .string(mime), "fileName": .string("image-\(index + 1).\(ext == "jpeg" ? "jpg" : ext)"), "content": .string(content)]
        }
    }

    static func checkFrame(_ params: GatewayJSON, summary: GatewaySummary) throws {
        let size = GatewayFrame.requestText(id: UUID().uuidString, method: "chat.send", params: params).utf8.count
        if size > summary.maxPayload {
            throw Refusal(text: "This message is \(OpenClawHub.megabytes(size)) on the wire; this Gateway takes up to \(OpenClawHub.megabytes(summary.maxPayload)). Send fewer or smaller images.")
        }
    }
}
