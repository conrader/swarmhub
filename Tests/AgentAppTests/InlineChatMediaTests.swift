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
    #expect(MediaExtractor.items(in: [sent]).first?.kind == .video)

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

@Test func publishedMediaReopensFromDiskOnlyForTheOriginalWorkspaceAndAccount() async throws {
    let store = temporaryStore()
    let directory = store.deletingLastPathComponent().appending(path: "cache")
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let message = UUID(), bytes = Data([1, 2, 3])
    let server = HerdrServer(id: "studio", name: "Studio", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "qa-studio")
    let item = try #require(HerdrPublishedResult(.init(id: 9, kind: "artifact", text: "", detail: "render.png")))
    let online = MockHTTPProtocol.serve { _ in (200, bytes) }
    let offline = MockHTTPProtocol.serve { _ in (503, ["error": "offline"]) }
    let first = HerdrClient(baseURL: URL(string: "http://\(online.host)")!, token: "a", session: online.session)
    var next = HerdrClient(baseURL: URL(string: "http://\(offline.host)")!, token: "a", session: offline.session)
    let saved = try await PublishedMediaCache(directory: directory).data(for: item, in: message, storeURL: store, server: server, client: first)
    #expect(saved == bytes)
    let reopened = PublishedMediaCache(directory: directory)
    #expect(try await reopened.data(for: item, in: message, storeURL: store, server: server, client: next) == bytes)
    #expect(MockHTTPProtocol.recorded(offline.host).isEmpty)

    var moved = server
    moved.sshHost = "another-studio"
    let unavailable = HerdrClient.Failure.http(503, "offline")
    await #expect(throws: unavailable) { try await reopened.data(for: item, in: message, storeURL: store, server: moved, client: next) }
    next = HerdrClient(baseURL: next.baseURL, token: "another-account", session: offline.session)
    await #expect(throws: unavailable) { try await reopened.data(for: item, in: message, storeURL: store, server: server, client: next) }
    #expect(MockHTTPProtocol.recorded(offline.host).count == 2)
}

@Test func publishedMediaCacheEvictsOlderPreviewsAndStillReturnsOversizedDownloads() async throws {
    let store = temporaryStore()
    let directory = store.deletingLastPathComponent().appending(path: "cache")
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let message = UUID()
    let http = MockHTTPProtocol.serve { request in
        let count = request.url?.path.contains("/3/") == true ? 12 : 4
        return (200, Data(repeating: 1, count: count))
    }
    let server = HerdrServer(id: "qa", name: "QA", kind: .address, address: "http://\(http.host)")
    let client = HerdrClient(baseURL: URL(string: server.address)!, token: "token", session: http.session)
    let cache = PublishedMediaCache(directory: directory, byteLimit: 6)
    func read(_ id: Int) async throws -> Data {
        let item = try #require(HerdrPublishedResult(.init(id: id, kind: "artifact", text: "", detail: "file.mp4")))
        return try await cache.data(for: item, in: message, storeURL: store, server: server, client: client)
    }
    #expect(try await read(1).count == 4)
    // Give the first entry a distinct age even on a coarse file-system clock.
    let old = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: old.path)
    #expect(try await read(2).count == 4)
    #expect(try await read(3).count == 12)
    #expect(try await read(2).count == 4)
    #expect(try await read(1).count == 4)
    #expect(MockHTTPProtocol.recorded(http.host).compactMap { $0.url?.path } == [1, 2, 3, 1].map { "/api/library/files/\($0)/download" })
}

@MainActor @Test func localReplyMediaUsesTheRecordedHostAndKeepsTheTemporaryFile() async throws {
    let storeURL = temporaryStore(), folder = storeURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(storeURL: storeURL, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let local = HerdrServer(id: "mac", name: "Mac", kind: .local, address: HerdrServer.loopback(port: 8787))
    let remote = HerdrServer(id: "dmt", name: "DMT", kind: .ssh, address: HerdrServer.loopback(port: 8788))
    store.saveHerdrServers([local, remote])
    let reply = ChatMessage(role: .assistant, content: "[formularz](/private/tmp/form.png) i ![film](file:///tmp/film%20PL.mp4). `[code](/tmp/no.jpg)`")
    let items = MediaExtractor.items(in: [reply])
    #expect(items.map(\.title) == ["formularz", "film"] && items.map(\.kind) == [.image, .video])
    reply.metadata["herdrJournal"] = "mac:3262"
    #expect(store.replyMediaIsOnThisMac(reply, target: nil))
    reply.metadata["herdrJournal"] = "dmt:3262"
    #expect(!store.replyMediaIsOnThisMac(reply, target: nil))
    #expect(ReplyMediaLink.fileURL(URL(string: "file://remote/tmp/form.png")!) == nil)
    let cache = PublishedMediaCache(directory: folder.appending(path: "cache"))
    let source = folder.appending(path: "form.png"), bytes = Data("original bytes".utf8)
    try bytes.write(to: source)
    let reference = URL(fileURLWithPath: source.resolvingSymlinksInPath().path).absoluteURL
    let linked = try #require(ReplyMediaLink.fileURL(reference))
    let saved = try await cache.localFile(linked, message: reply.id, storeURL: storeURL)
    try FileManager.default.removeItem(at: source)
    #expect(try Data(contentsOf: saved) == bytes)
    let reopened = try #require(ReplyMediaLink.fileURL(reference))
    #expect(reopened == linked)
    #expect(try await cache.localFile(reopened, message: reply.id, storeURL: storeURL) == saved)
    await #expect(throws: (any Error).self) { try await cache.localFile(source, message: UUID(), storeURL: storeURL) }
}

@Test func helperReplyMediaKeepsSessionAndJournalEntriesSeparate() {
    let server = HerdrServer(id: "workspace", name: "Mac", kind: .local, address: HerdrServer.loopback(port: 8787))
    func key(core: String = "core", created: UInt64 = 1, entry: [String] = ["managed", "2"]) -> UUID {
        HelperReplyMedia(server: server, core: core, agent: .init(address: "helper", createdMs: created), entry: entry).replyID
    }
    #expect(key() == key())
    #expect(key() != key(core: "next"))
    #expect(key() != key(created: 2))
    #expect(key() != key(entry: ["managed", "3"]))
    #expect(key(entry: ["ab", "c"]) != key(entry: ["a", "bc"]))
}
