import Foundation
import Testing
@testable import AgentApp

// MARK: Steer

/// Run IDs are scoped to the gateway/profile and session ID.
@Test func steerPostsInputToTheRunningRun() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true, "run_steer": true]) { request, _ in
        switch request.url!.path {
        case "/api/sessions/steer-s1/chat/stream": return .sse([("assistant.delta", ["run_id": "run_abc", "delta": "Hi"])], holdOpen: waitCeiling)
        case "/v1/runs/run_abc/steer": return .json(200, ["object": "hermes.run.steer", "run_id": "run_abc", "accepted": true])
        default: return .json(404, ["error": "no route"])
        }
    }
    let stream = try await backend.send(.init(sessionID: "steer-s1", systemPrompt: "p", messages: [(role: "user", content: "go")]))
    var iterator = stream.makeAsyncIterator()
    guard case .token("Hi")? = try await iterator.next() else { Issue.record("expected the first delta"); return }
    try await backend.steer(sessionID: "steer-s1", text: "Focus on the summary")
    let steer = try #require(ChatParityServer.requests(host).first { $0.path == "/v1/runs/run_abc/steer" })
    #expect(steer.method == "POST")
    #expect(steer.body as? [String: String] == ["input": "Focus on the summary"])
}

@Test func steerIsRefusedWithoutTheCapability() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true, "run_steer": false])
    await #expect(throws: BackendError.self) { try await backend.steer(sessionID: "s1", text: "x") }
    #expect(!ChatParityServer.requests(host).contains { $0.path.hasSuffix("/steer") })
}

@Test @MainActor func storeSteersOnlyWhenTheServerSupportsIt() async throws {
    let steering = ChatParityBackend(flags: ["run_steer"], opening: [.token("working"), .tool(ToolEvent(phase: .started, name: "terminal"))])
    let (store, bot) = parityStore(steering)
    #expect(store.send(text: "first"))
    try await waitUntil { (store.soleTurn?.steerAvailable == true) && store.soleTurn?.assistant?.activity?.current != nil }
    #expect(store.send(text: "  also check the logs "))
    try await steering.calls.wait { $0.contains("steer:session-main:also check the logs") }
    let bubble = try #require(bot.messages.last)
    #expect(bubble.role == .user && bubble.isSteer && bubble.content == "also check the logs")
    #expect(await steering.recorded().filter { $0.hasPrefix("send:") }.count == 1)
    store.stop()

    let plain = ChatParityBackend(flags: [])
    let (other, otherBot) = parityStore(plain)
    #expect(other.send(text: "first"))
    try await plain.calls.wait { $0.contains { $0.hasPrefix("send:") } }
    // The first token is read only after `steerAvailable` is settled for this run.
    try await waitUntil { otherBot.messages.last?.content == "working" }
    let count = otherBot.messages.count
    #expect(!(other.soleTurn?.steerAvailable == true))
    #expect(!other.send(text: "nudge"))
    #expect(otherBot.messages.count == count)
    other.stop()
}

// MARK: Fork / threads

@Test func forkPostsToTheSessionForkRoute() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_fork": true]) { request, body in
        guard request.url!.path == "/api/sessions/s1/fork" else { return .json(404, ["error": "no route"]) }
        return .json(201, ["object": "hermes.session", "session": ["id": body?["id"] as? String ?? "api_1", "parent_session_id": "s1", "source": "api_server"]])
    }
    let id = try await backend.forkSession(sessionID: "s1", id: "agentapp_thread_abc")
    #expect(id == "agentapp_thread_abc")
    let fork = try #require(ChatParityServer.requests(host).first { $0.path == "/api/sessions/s1/fork" })
    #expect(fork.method == "POST" && fork.body as? [String: String] == ["id": "agentapp_thread_abc"])

    let (offHost, offBackend) = ChatParityServer.serve(features: ["session_fork": false])
    await #expect(throws: BackendError.self) { _ = try await offBackend.forkSession(sessionID: "s1", id: nil) }
    #expect(!ChatParityServer.requests(offHost).contains { $0.path.hasSuffix("/fork") })
}

@Test @MainActor func replyInThreadForksAndSendsIntoTheThread() async throws {
    let url = temporaryStore()
    let backend = ChatParityBackend(flags: ["session_fork"])
    let (store, bot) = parityStore(backend, url: url)
    let source = ChatMessage(role: .assistant, content: "Here are three options."); bot.messages = [ChatMessage(role: .user, content: "help"), source]
    #expect(!store.canFork(bot))
    store.refreshFeatures(for: bot)
    try await waitUntil { store.canFork(bot) }
    store.replyInThread(to: source, in: bot)
    try await waitUntil { store.openThreadID != nil }
    let thread = try #require(bot.thread(for: source.id))
    #expect(thread.parentSessionID == "session-main")
    #expect(thread.hermesSessionID == "agentapp_thread_\(thread.id.uuidString.lowercased())")
    #expect(await backend.recorded().contains("fork:session-main:\(thread.hermesSessionID!)"))

    #expect(store.send(text: "Tell me more about the second"))
    let threadSend = "send:\(thread.hermesSessionID!):Tell me more about the second"
    try await backend.calls.wait { $0.contains(threadSend) }
    #expect(bot.messages.count == 2 && thread.messages.first?.content == "Tell me more about the second")
    store.stop(); try await waitUntil { !store.anyTurnRunning }

    let restored = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let restoredThread = try #require(restored.bots.first?.threads.first)
    #expect(restoredThread.parentMessageID == source.id && restoredThread.hermesSessionID == thread.hermesSessionID)
    #expect(restoredThread.replyCount >= 1)
}

@Test @MainActor func threadActionIsHiddenWithoutSessionFork() async throws {
    let backend = ChatParityBackend(flags: ["run_steer"])
    let (store, bot) = parityStore(backend)
    let source = ChatMessage(role: .assistant, content: "Answer"); bot.messages = [source]
    store.refreshFeatures(for: bot)
    try await waitUntil { store.botFeatures[bot.id] != nil }
    #expect(!store.canFork(bot))
    store.replyInThread(to: source, in: bot)
    try await Task.sleep(for: .milliseconds(50))
    #expect(bot.threads.isEmpty && store.openThreadID == nil)
    #expect(await backend.recorded().allSatisfy { !$0.hasPrefix("fork:") })
}

// MARK: Attachments on the wire

@Test func imagesGoAsContentPartsOnTheSessionStream() async throws {
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in .sse([("run.completed", ["run_id": "r"])]) }
    let image = "data:image/png;base64,iVBORw0KGgo="
    let stream = try await backend.send(.init(sessionID: "s1", systemPrompt: "p", messages: [(role: "user", content: "What is this?")], images: [image]))
    for try await _ in stream {}
    let body = try #require(ChatParityServer.requests(host).first { $0.path == "/api/sessions/s1/chat/stream" }?.body)
    let parts = try #require(body["input"] as? [[String: Any]])
    #expect(parts.count == 2)
    #expect(parts[0]["type"] as? String == "text" && parts[0]["text"] as? String == "What is this?")
    #expect(parts[1]["type"] as? String == "image_url" && (parts[1]["image_url"] as? [String: String])?["url"] == image)

    let (plainHost, plainBackend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { _, _ in .sse([("run.completed", ["run_id": "r"])]) }
    for try await _ in try await plainBackend.send(.init(sessionID: "s2", systemPrompt: "p", messages: [(role: "user", content: "text only")])) {}
    #expect(ChatParityServer.requests(plainHost).first { $0.path == "/api/sessions/s2/chat/stream" }?.body?["input"] as? String == "text only")
}

@Test func imagesGoAsContentPartsOnLegacyChatCompletions() async throws {
    let (host, backend) = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: [DONE]\n\n".utf8)) }
    let image = "data:image/jpeg;base64,/9j/4AAQ"
    for try await _ in try await backend.send(.init(sessionID: "s1", systemPrompt: "p", messages: [(role: "user", content: "earlier"), (role: "assistant", content: "ok"), (role: "user", content: "")], images: [image])) {}
    let body = try #require(ChatParityServer.requests(host).first { $0.path == "/v1/chat/completions" }?.body)
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages[1]["content"] as? String == "earlier")
    let parts = try #require(messages.last?["content"] as? [[String: Any]])
    #expect(parts.count == 1 && parts[0]["type"] as? String == "image_url")
}

@Test @MainActor func storeSendsAttachedImagesAndInlineTextFiles() async throws {
    let backend = ChatParityBackend(flags: [])
    let (store, bot) = parityStore(backend)
    let image = try #require(store.prepareAttachment(imageData: syntheticImage(width: 40, height: 30, alpha: false), name: "shot.png"))
    let file = ChatAttachment(id: UUID(), kind: .text, name: "notes.md", mimeType: "text/markdown", byteCount: 5, text: "hello")
    #expect(store.send(text: "", attachments: [image, file]))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:") } }
    let sent = try #require(await backend.images().first)
    #expect(sent.count == 1 && sent[0].hasPrefix("data:image/png;base64,"))
    #expect(await backend.recorded().first { $0.hasPrefix("send:") } == "send:session-main:File: notes.md\n```\nhello\n```")
    #expect(bot.messages.first?.attachments.count == 2)
    store.stop()
}
