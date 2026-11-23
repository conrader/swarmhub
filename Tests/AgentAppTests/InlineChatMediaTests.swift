import AVKit
import SwiftUI
import Testing
@testable import AgentApp

@MainActor @Test func chatDisplaysPublishedImagesAndPlaysPublishedAndAttachedVideos() async throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/chat-media/clip.mp4")
    let clip = try Data(contentsOf: source)
    let renderer = ImageRenderer(content: Text("Moonrise preview").font(.title.bold()).foregroundStyle(.black).padding().background(.white))
    let png = try #require(renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
    let http = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/library/files/51/download": (200, png)
        case "/api/library/files/52/download": (200, clip)
        default: (404, [:])
        }
    }
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let server = HerdrServer(id: "media", name: "Media", kind: .address, address: "http://\(http.host)")
    store.saveHerdrServer(server, token: "fixture")
    store.herdrClientSetup = { $0.session = http.session }

    let reply = ChatMessage(role: .assistant, content: "Here are the renders.")
    reply.publishedResults = HerdrReplyResults(serverID: server.id, items: [
        try #require(HerdrPublishedResult(.init(id: 51, kind: "artifact", text: "", detail: "render.png"))),
        try #require(HerdrPublishedResult(.init(id: 52, kind: "artifact", text: "", detail: "scene.mp4")))
    ])
    let upload = try store.attachmentEncoder.prepare(fileURL: source)
    let payload = try store.attachmentEncoder.taskFile(for: upload)
    #expect(upload.kind == .video && payload.data == clip)
    let sent = ChatMessage(role: .user, content: "Review my clip.")
    sent.attachments = [upload]

    _ = NSApplication.shared
    let size = NSSize(width: 700, height: 840)
    let host = NSHostingView(rootView: VStack {
        MessageView(message: sent)
        MessageView(message: reply)
    }.environmentObject(store).frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }

    func players(in view: NSView) -> [AVPlayer] {
        if let player = (view as? AVPlayerView)?.player { return [player] }
        return view.subviews.flatMap { players(in: $0) }
    }
    try await waitUntil {
        host.layoutSubtreeIfNeeded()
        let media = players(in: host)
        return media.count == 2 && media.allSatisfy { $0.currentItem?.status == .readyToPlay }
    }
    let shown = try await mountedText(host)
    #expect(shown.contains("Moonrise preview"), "The reply actually renders the pixels of the published image.")
    for player in players(in: host) {
        #expect(player.rate == 0)
        player.play()
        try await waitUntil { player.currentTime().seconds > 0 }
        player.pause()
    }
}
