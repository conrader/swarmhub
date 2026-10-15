import AppKit
import SwiftUI
import Testing
import Vision
@testable import AgentApp

/// Exercise the mounted sidebar as messages arrive, then render both disconnected detail states.
@Test @MainActor func sidebarReordersInPlaceAndDisconnectedBotsShowTheirActions() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let rapper = Bot(name: "Rapper", messages: [ChatMessage(role: .user, content: "Earlier message", createdAt: Date(timeIntervalSince1970: 100))])
    let reactor = Bot(name: "Reactor", messages: [ChatMessage(role: .assistant, content: "Latest reply", createdAt: Date(timeIntervalSince1970: 200))])
    store.bots = [rapper, reactor]; store.groups = []; store.selectedBot = nil
    let target = "https://box.example"
    let main = BoxProfile(name: "default", hasKey: true, state: .needsKey), cfo = BoxProfile(name: "cfo", hasKey: false, state: .adoptable)
    store.boxProfiles[target] = [main, cfo]; store.open(cfo, on: target)
    let size = NSSize(width: 920, height: 620)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: SidebarManagementFixture().environmentObject(store).defaultAppStorage(store.defaults).environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
    defer { window.contentView = nil; window.close() }
    let before = try await sidebarWords(host)
    #expect(try y("Reactor", in: before) > y("Rapper", in: before))
    #expect(before.contains { $0.text.contains("Delete Bot") } && before.contains { $0.text.contains("Paste its key") })
    rapper.messages.append(ChatMessage(role: .user, content: "Newest sent message", createdAt: Date(timeIntervalSince1970: 300)))
    store.objectWillChange.send()
    let after = try await sidebarWords(host, save: "disconnected-dark")
    #expect(try y("Rapper", in: after) > y("Reactor", in: after))
    store.open(main, on: target)
    let needsKey = try await sidebarWords(host, save: "needs-key-dark")
    #expect(needsKey.contains { $0.text.contains("Key needed") } && needsKey.contains { $0.text.contains("Delete Bot") })
    if let folder = ProcessInfo.processInfo.environment["SWARMHUB_SIDEBAR_PREVIEW_DIR"] {
        let view = SidebarManagementFixture().environmentObject(store).defaultAppStorage(store.defaults)
        let light = try #require(await SnapshotRenderer.png(view, size: size, scheme: .light))
        try light.write(to: URL(fileURLWithPath: folder).appending(path: "needs-key-light.png"))
    }
}

private struct SidebarManagementFixture: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 1) {
            SidebarView(selection: .constant(store.selectedBot)).frame(width: 300)
            if let selection = store.selectedBoxProfile, let profile = store.selectedDisconnectedProfile {
                BoxProfileDetailView(profile: profile, target: selection.target)
            }
        }.background(AppColor.chat)
    }
}

@MainActor private func sidebarWords(_ host: NSView, save: String? = nil) async throws -> [(text: String, y: CGFloat)] {
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = host.bounds.size; host.cacheDisplay(in: host.bounds, to: bitmap)
    if let save, let folder = ProcessInfo.processInfo.environment["SWARMHUB_SIDEBAR_PREVIEW_DIR"] {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "\(save).png"))
    }
    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
    return recognition.results?.compactMap { result in result.topCandidates(1).first.map { ($0.string, result.boundingBox.midY) } } ?? []
}

private func y(_ text: String, in words: [(text: String, y: CGFloat)]) throws -> CGFloat {
    try #require(words.first { $0.text == text }).y
}
