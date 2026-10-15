import AppKit
import Foundation
import Testing
import Vision
@testable import AgentApp

/// The fixture sends the first part and keeps the HTTP response open while the test reads the UI.
/// This detects buffering that a fixture delivering every SSE event at once cannot catch.
@Test(arguments: [false, true]) @MainActor func replyTextIsVisibleBeforeTheHTTPStreamFinishes(legacy: Bool) async throws {
    let sessionID = "streaming-\(UUID().uuidString)"
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { request, _ in
        if request.url?.path.hasSuffix("/stop") == true { return .json(200, ["status": "stopping"]) }
        if legacy {
            return .sse([("message", ["choices": [["delta": ["content": "The reply is arriving live."]]]])], holdOpen: waitCeiling)
        }
        return .sse([("assistant.delta", ["run_id": "run-stream", "delta": "The reply is arriving live."])], holdOpen: waitCeiling)
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Stream test", backend: .hermes, hermesSessionID: sessionID)
    store.bots = [bot]; store.selectedBot = bot
    defer { store.stop() }
    #expect(store.send(text: "A synthetic question"))
    try await waitUntil { bot.messages.last?.content == "The reply is arriving live." }
    let assistant = try #require(bot.messages.last)
    #expect(assistant.isStreaming && store.isStreaming)
    let request = try #require(ChatParityServer.requests(host).first { $0.path.hasSuffix(legacy ? "/chat/completions" : "/chat/stream") })
    #expect(request.method == "POST")

    // Read the rendered text, not just the model: the first chunk must be visible beside the spinner.
    let png = try #require(await SnapshotRenderer.png(MessageView(message: assistant).environmentObject(store),
                                                      size: NSSize(width: 720, height: 240)))
    let bitmap = try #require(NSBitmapImageRep(data: png))
    let image = try #require(bitmap.cgImage)
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([recognition])
    let rendered = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    #expect(rendered.contains("The reply is arriving live."))
    #expect(assistant.isStreaming && store.isStreaming, "Rendering must not wait for stream completion.")
    store.stop()
    try await waitUntil { store.isIdle }
}

@Test(arguments: [false, true]) func chatRequestsNegotiateUncompressedEventStreams(legacy: Bool) async throws {
    let sessionID = "headers-\(UUID().uuidString)"
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { request, _ in
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        if legacy { return .init(body: Data("data: [DONE]\n\n".utf8)) }
        return .sse([("run.completed", ["run_id": "run-headers"])])
    }
    for try await _ in try await backend.send(.init(sessionID: sessionID, systemPrompt: "Synthetic", messages: [(role: "user", content: "Test")])) {}
    #expect(ChatParityServer.requests(host).contains { $0.path.hasSuffix(legacy ? "/chat/completions" : "/chat/stream") })
}
