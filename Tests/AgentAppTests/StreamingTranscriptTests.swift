import AppKit
import SwiftUI
import Testing
import Vision
@testable import AgentApp

/// Keep the same mounted chat through the empty, partial and completed states. A snapshot mounted
/// after text has arrived would miss a row that fails to update while it is already on screen.
@Test @MainActor func mountedChatUpdatesAnEmptyReplyAsChunksArrive() async throws {
    let backend = ControlledReplyBackend()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Streaming fixture", backend: .hermes, hermesSessionID: "synthetic-stream")
    store.bots = [bot]; store.selectedBot = bot
    #expect(store.send(text: "A synthetic question"))
    let assistant = try #require(bot.messages.last)
    let size = NSSize(width: 720, height: 600)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: ChatView(bot: bot).environmentObject(store).defaultAppStorage(store.defaults)
        .environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    defer { store.stop(); window.contentView = nil; window.close() }
    try await waitUntil { await backend.ready }
    #expect(assistant.content.isEmpty && assistant.isStreaming)
    let empty = try await mountedText(host)
    #expect(!empty.contains("Words arrive before completion."))

    await backend.emit(.token("Words arrive before completion."))
    try await waitUntil { assistant.content == "Words arrive before completion." }
    let partial = try await mountedText(host)
    #expect(partial.contains("Words arrive before completion."))
    #expect(assistant.isStreaming && store.anyTurnRunning)

    await backend.emit(.token(" More words arrive later."))
    try await waitUntil { assistant.content.hasSuffix("More words arrive later.") }
    let next = try await mountedText(host)
    #expect(next.contains("More words arrive later."))
    #expect(assistant.isStreaming && store.anyTurnRunning)

    await backend.finish()
    try await waitUntil { !store.anyTurnRunning }
    #expect(!assistant.isStreaming && bot.messages.last?.id == assistant.id)
}

@MainActor private func mountedText(_ host: NSView) async throws -> String {
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
    let size = host.bounds.size
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try #require(bitmap.cgImage)
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([recognition])
    return recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
}

private actor ControlledReplyBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    private var continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    var ready: Bool { continuation != nil }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func emit(_ event: AgentEvent) { continuation?.yield(event) }
    func finish() { continuation?.yield(.completed); continuation?.finish(); continuation = nil }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .disconnectedLegacy }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "Synthetic" }
}
