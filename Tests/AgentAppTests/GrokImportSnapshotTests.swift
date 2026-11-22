import AppKit
import Foundation
import Security
import Testing
@testable import AgentApp

// P10d: every step of the import sheet rendered offscreen with injected state (`SnapshotRenderer.png`), written to
// `$TMPDIR/AgentAppSnapshots-grok-import/` for review. Synthetic data only; nothing is read from the real Mac.

private let snapshotFolder = FileManager.default.temporaryDirectory
    .appending(path: "AgentAppSnapshots-grok-import", directoryHint: .isDirectory)

private func distinctColours(_ image: NSBitmapImageRep) -> Int {
    var seen = Set<String>()
    for x in stride(from: 0, to: image.pixelsWide, by: 12) { for y in stride(from: 0, to: image.pixelsHigh, by: 12) {
        guard let c = image.colorAt(x: x, y: y) else { continue }
        seen.insert(String(format: "%.2f%.2f%.2f", c.redComponent, c.greenComponent, c.blueComponent))
    } }
    return seen.count
}

@MainActor private func render(_ coordinator: GrokImportCoordinator, _ store: AppStore, name: String) async throws {
    let view = GrokImportSheet(coordinator: coordinator).environmentObject(store).defaultAppStorage(store.defaults)
    let data = try #require(await SnapshotRenderer.png(view, size: NSSize(width: 680, height: 680), scale: 1))
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(image.pixelsWide == 680 && image.pixelsHigh == 680, "\(name)")
    #expect(distinctColours(image) > 4, "\(name) looks blank")
    try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
    try data.write(to: snapshotFolder.appending(path: "\(name).png"))
}

/// Default suite: the first step only.
@MainActor @Test func theImportSheetsFirstStepRenders() async throws {
    let world = try GrokWorld()
    let store = world.store(server: "https://box.test/v1")
    let found = makeCoordinator(world, store)
    await found.scan()
    try await render(found, store, name: "1-found")
}


/// A refusal with a reason: Grok answers the first request with 401 and says why. The sheet asks macOS once, imports
/// the recent messages kept on this Mac instead, says what Grok said, and opens on Recent messages the next time.
@MainActor @Test func aRefusalOnTheFirstRequestFallsBackToRecentMessagesAndIsRemembered() async throws {
    let world = try GrokWorld()
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0)
    try plist.write(to: world.location.app.appending(path: "Contents/Info.plist"))
    let said = "Grok Bot requires an Ultra subscription or a Premium self-serve team seat"
    world.fake.intercept = { _, _ in .http(401, Array(#"{"code":"unauthenticated","message":"\#(said)"}"#.utf8)) }
    let store = world.store(server: "https://box.test/v1")
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    #expect(coordinator.mode == .full && coordinator.versionDriftNote == "Grok Bot is 1.2.3; this import was last checked against 0.70.2.")
    await runFull(coordinator)
    #expect(coordinator.step == .finished)
    let refusal = try #require(coordinator.fallback)
    #expect(refusal.reason == .signInInvalid && refusal.serverMessage == said)
    #expect(coordinator.requests == 1 && world.passwords.reads == 1)
    #expect(coordinator.outcomes.count == 4 && coordinator.outcomes.allSatisfy { $0.row.coverage == .cacheOnly })
    #expect(coordinator.lastRefusal?.summary == "Grok said: “\(said)” (HTTP 401).")
    try await render(coordinator, store, name: "4-done-after-refusal")

    // The next sheet session opens on Recent messages and says why, so macOS is not asked for nothing.
    let next = makeCoordinator(world, store)
    await next.scan()
    #expect(next.mode == .recent && next.refusalNote?.contains(said) == true)
    try await render(next, store, name: "1-found-after-refusal")

    // All history working again forgets the stop.
    world.fake.intercept = nil
    next.mode = .full
    await runFull(next)
    #expect(next.step == .finished && next.fallback == nil && next.lastRefusal == nil)
    #expect(GrokRefusalNote.load(store.defaults) == nil)
}

/// Every other step of the sheet, rendered for review: the macOS explanation, a run in flight, a network pause, done.
@MainActor @Test func everyStepOfTheImportSheetRenders() async throws {
    let world = try GrokWorld(history: [GrokRunIDs.jarvis: 30, GrokRunIDs.finance: 25, GrokRunIDs.plain: 3, GrokRunIDs.group: 4])
    world.fake.pageCap = 10
    let reached = GrokSwitch(), release = DispatchSemaphore(value: 0)
    // Request 0 is the canary, 1-3 Jarvis's pages, 4 Finance's first page: it is held while the sheet is rendered.
    world.fake.intercept = { index, _ in
        if index == 4 { reached.isOn = true; release.wait() }
        return nil
    }
    let store = world.store(server: "https://box.test/v1")
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await coordinator.proceed()
    #expect(coordinator.step == .permission)
    try await render(coordinator, store, name: "2-permission")
    coordinator.continueToMacOS()
    try await grokWait { reached.isOn }
    try await render(coordinator, store, name: "3-importing")
    release.signal()
    await coordinator.settled()
    #expect(coordinator.step == .finished && coordinator.fallback == nil)
    try await render(coordinator, store, name: "4-done")

    let offline = try GrokWorld()
    offline.fake.intercept = { index, _ in index >= 2 ? .fail(.timedOut) : nil }
    let second = offline.store(server: "https://box.test/v1")
    let paused = makeCoordinator(offline, second)
    await paused.scan()
    await runFull(paused)
    #expect(paused.step.isPaused)
    try await render(paused, second, name: "3-paused")
}
