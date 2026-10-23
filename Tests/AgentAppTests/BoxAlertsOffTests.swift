import AppKit
import SwiftUI
import Testing
import Vision
@testable import AgentApp

// rel066: off-app alerts are switched off in this release (`AppStore.boxAlertsShipped`; the box's twin is
// `swarm_alerts_service.ON`, sim/test_alerts_off.py). A store as the app makes it sends nothing about alerts to a box:
// no settings, allowlist or revocation push, no test or status call (so the app installs no service), no presence lease;
// Settings shows no alerts section. Loops still go to the box at quit (the handoff tests run with alerts off).

@Test @MainActor func offAppAlertsAreInertWhileSwitchedOff() async throws {
    let server = FakeJobsServer()
    let (store, bot, host) = routinesStore(server)
    var calls: [[String]] = []
    store.alertsControl = { _, arguments in
        calls.append(arguments)
        return alertsPanelJSON(action: arguments[2], configured: true, enabled: true, running: true, result: ["saved": true], revision: 1)
    }
    store.boxAlerts.idleSeconds = { 5 }  // At the Mac: a lease would be due.
    let target = store.connection(of: bot)
    var settings = AlertSettings(); settings.ntfyURL = "https://ntfy.sh/konrad-alerts"
    // A box a 0.6.5 app turned alerts on for, its settings kept here without an allowlist: every automatic push is due.
    store.defaults.set(true, forKey: "alerts.on." + target)
    store.defaults.set(try JSONEncoder().encode(settings), forKey: "alerts.settings." + target)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    await store.renewAlertPresenceIfDue(now: now)
    await store.syncAlertProfiles(now: now.addingTimeInterval(86_400))
    let twin = Bot(name: "Twin", backend: .hermes, hermesProfile: "twin")
    store.bots.append(twin)
    store.delete(twin)  // A revocation would be owed at once.
    for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await store.saveAlerts(settings, ntfyToken: "tk_secret_123", emailPassword: "", on: target) == false)
    await store.refreshAlerts(on: target)
    await store.sendTestAlert(on: target)
    await store.turnOffAlerts(on: target)
    store.handOffForQuit(budget: 2)
    #expect(calls.isEmpty, "no alerts call reached the box: \(calls.map { $0.prefix(3) })")
    #expect(store.alertServers.isEmpty && store.presenceEndings.isEmpty)
    #expect(server.jobIDs.isEmpty && !requestLines(host).contains { !$0.hasPrefix("GET ") }, "no presence lease: \(requestLines(host))")

    let size = NSSize(width: 720, height: 900)
    _ = NSApplication.shared
    let view = NSHostingView(rootView: Form { SettingsAlertsPane() }.formStyle(.grouped).environmentObject(store)
        .defaultAppStorage(store.defaults).frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    defer { window.contentView = nil; window.close() }
    let text = try await renderedText(view)
    #expect(text.contains("Muting a bot") || text.contains("Avatar motion"), "the pane rendered: \(text)")
    #expect(!text.contains("SwarmHub is closed") && !text.contains("ntfy"), "no off-app alerts section: \(text)")

    // A loop that ends by its count still goes to the box at quit, alerts off.
    let (quitting, loopBot, _, bodies, _, _) = handoffStore(alerts: true)
    quitting.automations[loopBot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()))
    quitting.handOffForQuit(budget: 5)
    #expect(bodies.all.count == 1 && quitting.automations[loopBot.id]?.boxHandoff?.kind == .loop)
}

@MainActor private func renderedText(_ host: NSView) async throws -> String {
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
