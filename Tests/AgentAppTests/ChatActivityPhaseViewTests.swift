import AppKit
import SwiftUI
import Testing
import Vision
@testable import AgentApp

/// Check all three labels in an already-mounted reply, bot row and group row, rather than recreating
/// the views after each event. The window stays off screen and contains synthetic content only.
@Test @MainActor func activityLabelsUpdateInChatAndBothSidebarRows() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Bot fixture"), group = GroupChat(name: "Group fixture", memberIDs: [bot.id])
    let reply = ChatMessage(role: .assistant, content: "", isStreaming: true)
    bot.messages = [reply]; group.messages = [reply]; store.bots = [bot]; store.groups = [group]
    store.isStreaming = true; store.streamingBotID = bot.id; store.streamingAssistant = reply; store.streamingConversation = group
    let size = NSSize(width: 720, height: 360)
    let view = VStack(alignment: .leading, spacing: 12) {
        BotRow(bot: bot, drafts: store.drafts, selected: false, botToDelete: .constant(nil)).frame(width: 320)
        GroupRow(group: group, drafts: store.drafts, botToDelete: .constant(nil)).frame(width: 320)
        MessageView(message: reply)
        Spacer()
    }.padding(12).frame(width: size.width, height: size.height, alignment: .topLeading).background(AppColor.chat)
        .environmentObject(store).defaultAppStorage(store.defaults).environment(\.colorScheme, .dark)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
    defer { window.contentView = nil; window.close() }
    #expect(try await phaseLabels(in: host, named: "Thinking") >= 3)

    var activity = ToolActivity()
    activity.apply(.init(phase: .started, name: "execute_code"), at: .now)
    reply.activity = activity; store.objectWillChange.send()
    #expect(try await phaseLabels(in: host, named: "Working") >= 3)

    activity.apply(.init(phase: .completed, name: "execute_code"), at: .now)
    reply.activity = activity; store.objectWillChange.send()
    #expect(try await phaseLabels(in: host, named: "Thinking") >= 3)

    reply.content = "Reply text arrives in pieces."; reply.lastTextAt = .now; store.objectWillChange.send()
    #expect(try await phaseLabels(in: host, named: "Typing") >= 3)
    reply.isStreaming = false; store.isStreaming = false
    #expect(try await phaseLabels(in: host, named: "Typing") == 0)
}

@MainActor private func phaseLabels(in host: NSView, named phase: String) async throws -> Int {
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
    let size = host.bounds.size
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size; host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try #require(bitmap.cgImage)
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([recognition])
    let count = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.filter { $0.contains(phase) }.count ?? 0
    if count > 0, let path = ProcessInfo.processInfo.environment["SWARMHUB_ACTIVITY_PREVIEW_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(phase.lowercased()).png"))
    }
    return count
}
