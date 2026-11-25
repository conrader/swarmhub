import AppKit
import Combine
import CoreMedia
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Testing
@preconcurrency import BotAvatarsKit
@testable import AgentApp

// Opt-in, on a logged-in Mac. The comparison runner installs this same test in both trees.
private struct ProbeWorkspace: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $store.selectedBot).frame(width: 280)
            if let bot = store.selectedBot {
                ChatView(bot: bot).id(bot.id)
            }
        }.environmentObject(store).defaultAppStorage(store.defaults)
    }
}

private class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct WindowFrame: Sendable {
    let time: Double
    let title: UInt64?
}

private final class WindowFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "responsiveness.window-frames")
    private var frames: [WindowFrame] = []
    private let titleRect: CGRect
    @MainActor init(header: CGRect) {
        // The title follows the 30 pt avatar and 11 pt gap in the production ChatView header.
        titleRect = CGRect(x: header.minX + ChromeMetrics.headerPadding + 41, y: header.midY - 10, width: 105, height: 20)
    }
    func snapshot() -> [WindowFrame] { queue.sync { frames } }

    func firstFrame(with title: UInt64, since start: Double) -> WindowFrame? {
        queue.sync { frames.lastIndex(where: { $0.time < start }).flatMap { previous in
            frames[(previous + 1)...].first { $0.title == title }
        } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachment = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = attachment[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let ticks = attachment[.displayTime] as? UInt64,
              let image = CMSampleBufferGetImageBuffer(sample) else { return }
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return }
        guard CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            .contains(titleRect) else { return }
        let stride = CVPixelBufferGetBytesPerRow(image)
        var hash: UInt64 = 14695981039346656037, ink = false
        for y in Int(titleRect.minY)..<Int(titleRect.maxY) {
            for x in Int(titleRect.minX)..<Int(titleRect.maxX) {
                let i = y * stride + x * 4
                let dark = max(bytes[i], max(bytes[i + 1], bytes[i + 2])) < 110
                ink = ink || dark
                hash = (hash ^ (dark ? 1 : 0)) &* 1099511628211
            }
        }
        frames.append(WindowFrame(time: CMClockMakeHostTimeFromSystemUnits(ticks).seconds, title: ink ? hash : nil))
    }
}

private func uptimeSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

private func distribution(_ samples: [Double]) -> [String: Any] {
    let sorted = samples.sorted()
    return ["samples_ms": samples, "count": samples.count,
            "p95_ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "worst_ms": sorted.last!,
            "over_33_4_ms": sorted.filter { $0 > 33.4 }.count, "over_50_ms": sorted.filter { $0 > 50 }.count,
            "over_100_ms": sorted.filter { $0 > 100 }.count]
}

/// The command-line test host has a run loop but may have no NSApplication.run event pump.
/// Queue the matching mouse-up first so a button that tracks inside mouseDown can consume it.
@MainActor private func click(_ window: NSWindow, at point: CGPoint) throws {
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
    let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
    NSApp.postEvent(up, atStart: true)
    window.sendEvent(down)
    if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
       pending.windowNumber == window.windowNumber,
       let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
        window.sendEvent(release)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWARM_RESPONSIVENESS_REPORT"] != nil))
@MainActor func syntheticWindowResponsiveness() async throws {
    let env = ProcessInfo.processInfo.environment
    let report = URL(fileURLWithPath: try #require(env["SWARM_RESPONSIVENESS_REPORT"]))
    let count = try #require(env["SWARM_RESPONSIVENESS_BOTS"].flatMap(Int.init))
    try #require([1, 4].contains(count))
    let backends = (0..<4).map { _ in ScriptedTurnBackend() }
    let bots = (0..<4).map { index in
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        let messages = (0..<96).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
            content: "Synthetic history row \($0). " + String(repeating: "A paragraph of fixture text. ", count: 8)) }
        return Bot(id: id, name: "Fixture \(index + 1)", backend: .mock, notificationsEnabled: false, messages: messages)
    }
    let byID = Dictionary(uniqueKeysWithValues: zip(bots.map(\.id), backends))
    let fixture = report.deletingPathExtension()
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
    let defaults = try #require(UserDefaults(suiteName: fixture.appending(path: "defaults").path))
    let store = AppStore(storeURL: fixture.appending(path: "store.json"), autoStart: false,
                         backendFactory: { byID[$0.id]! }, keyStore: InMemoryKeyStore(), defaults: defaults)
    store.grokBotPresent = false
    store.bots = bots
    store.open(bots[0], remember: false)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = ProbeWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 720),
                             styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ProbeWorkspace(store: store).preferredColorScheme(.light))
    window.hasShadow = false
    window.setContentSize(NSSize(width: 1120, height: 720))
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    AvatarMotionSettings.shared.probeOverride = .byContext
    defer {
        AvatarMotionSettings.shared.probeOverride = nil
        for bot in bots where store.isStreaming(in: bot) { store.stop(bot) }
        window.close()
    }
    try await waitUntil(timeout: .seconds(8)) {
        window.occlusionState.contains(.visible) && app.isActive && UISmokeProbe.liveAvatarViews >= 5
    }
    for index in 0..<count {
        let bot = bots[index]
        try #require(store.send(text: "Synthetic work", bot: bot, conversation: bot, replyToID: nil))
        try await backends[index].calls.wait { $0.contains("send:Synthetic work") }
        await backends[index].emit(.token("Beginning. "))
    }
    try await waitUntil(timeout: .seconds(5)) { bots.prefix(count).allSatisfy { $0.messages.last?.content == "Beginning. " } }
    try #require(store.runningTurns.count == count && BotAvatarClock.shared.isRunning)

    let available = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let source = try #require(available.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
    let config = SCStreamConfiguration()
    config.width = 1120
    config.height = 720
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    if #available(macOS 15.0, *) { config.ignoreShadowsSingleWindow = true }
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: source), configuration: config, delegate: nil)
    let header = try #require(ChromeProbes.frames(in: window)["chat_header"])
    let recorder = WindowFrames(header: header)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
    try await stream.startCapture()
    try await waitUntil(timeout: .seconds(5)) { recorder.snapshot().last?.title != nil }
    let first = try #require(recorder.snapshot().last?.title)
    store.open(bots[1], remember: false)
    try await waitUntil(timeout: .seconds(5)) {
        let samples = recorder.snapshot().suffix(3)
        return UISmokeProbe.renderedChats.contains(bots[1].id) && samples.count == 3 &&
            samples.allSatisfy { $0.title != nil && $0.title != first && $0.title == samples.last?.title }
    }
    let second = try #require(recorder.snapshot().last?.title)
    store.open(bots[0], remember: false)
    try await waitUntil(timeout: .seconds(5)) { recorder.snapshot().last?.title == first }
    let titles = [first, second]
    let list = try #require(ChromeProbes.frames(in: window)["sidebar_list"])
    let rows = store.sidebarChats
    let points = try bots.prefix(2).map { bot in
        let index = try #require(rows.firstIndex { $0.id == bot.id })
        let y = list.minY + 4 + (CGFloat(index) + 0.5) * SidebarMetrics.rowHeight
        return CGPoint(x: list.midX, y: window.frame.height - y)
    }
    let origin = ContinuousClock.now.advanced(by: .milliseconds(200))
    store.turns.lastAutosave = origin
    var broadcasts = 0
    let observation = store.objectWillChange.sink { broadcasts += 1 }
    defer { observation.cancel() }
    let producers = backends.prefix(count).map { backend in
        Task.detached {
            var text = "Beginning. "
            for n in 0..<800 {
                try await Task.sleep(until: origin.advanced(by: .milliseconds(n * 10)), clock: .continuous)
                text += "word "
                if n.isMultiple(of: 10) { await backend.emit(.replace(text)) } else { await backend.emit(.token("word ")) }
                if n % 100 == 20 { await backend.emit(step(.started, id: "call-\(n / 100)")) }
                if n % 100 == 35 { await backend.emit(step(.completed, id: "call-\(n / 100)")) }
            }
            await backend.emit(.completed)
            await backend.end()
        }
    }
    defer { producers.forEach { $0.cancel() } }
    let frameStart = BotAvatarClock.shared.frame
    BotAvatarClock.shared.stats.reset()
    // The click source runs even when the app's main actor is busy.
    let samples = try await Task.detached {
        var latency: [Double] = [], mainQueue: [Double] = []
        var startOfClicks = 0.0, lastVisible = 0.0
        for n in 0..<24 {
            try await Task.sleep(until: origin.advanced(by: .milliseconds(600 + 280 * n)), clock: .continuous)
            let target = (n + 1) % 2
            let start = uptimeSeconds()
            if n == 0 { startOfClicks = start }
            let dispatch = try await MainActor.run {
                let time = uptimeSeconds()
                try #require(store.runningTurns.count == count && window.occlusionState.contains(.visible) && app.isActive)
                try click(window, at: points[target])
                return time
            }
            let timeout = ContinuousClock.now.advanced(by: .seconds(5))
            while recorder.firstFrame(with: titles[target], since: start) == nil {
                guard ContinuousClock.now < timeout else {
                    throw NSError(domain: "ResponsivenessSmoke", code: n,
                                  userInfo: [NSLocalizedDescriptionKey: "Click \(n + 1) did not display the target chat within 5 s"])
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            lastVisible = try #require(recorder.firstFrame(with: titles[target], since: start)).time
            latency.append((lastVisible - start) * 1000)
            mainQueue.append((dispatch - start) * 1000)
        }
        return (latency: latency, mainQueue: mainQueue, start: startOfClicks, end: lastVisible)
    }.value
    try #require(store.selectedBot === bots[0])
    for producer in producers { try await producer.value }
    try await waitUntil(timeout: .seconds(15)) { !store.anyTurnRunning }
    try await stream.stopCapture()
    let frames = recorder.snapshot()
    let gaps = zip(frames, frames.dropFirst()).compactMap { before, after -> Double? in
        guard after.time >= samples.start && after.time <= samples.end else { return nil }
        return (after.time - before.time) * 1000
    }
    try #require(!gaps.isEmpty)
    let avatar = BotAvatarClock.shared
    let stats = avatar.stats
    let result: [String: Any] = ["streams": count, "text_events_per_stream": 801, "scripted_clicks": samples.latency.count,
        "click_to_visible_chat": distribution(samples.latency),
        "main_queue_wait_proxy": distribution(samples.mainQueue), "window_frame_gaps": distribution(gaps),
        "store_broadcasts": broadcasts, "avatar_frames": avatar.frame - frameStart, "avatar_ticks": stats.ticks, "avatar_draws": stats.draws,
        "avatar_draw_cpu_seconds": stats.drawSeconds, "avatar_tick_cpu_seconds": stats.tickSeconds,
        "live_avatar_views": UISmokeProbe.liveAvatarViews, "display_hz_max": window.screen?.maximumFramesPerSecond ?? 0,
        "os": ProcessInfo.processInfo.operatingSystemVersionString]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
    #expect(avatar.frame > frameStart && stats.draws > 0 && window.occlusionState.contains(.visible))
    #expect(bots[0].unreadCount == 0 && bots.prefix(count).dropFirst().allSatisfy { $0.unreadCount == 1 })
    #expect(bots.prefix(count).allSatisfy { $0.messages.last?.activity?.total == 8 })
    #expect(bots.prefix(count).allSatisfy { $0.messages.last?.content == "Beginning. " + String(repeating: "word ", count: 800) })
}
