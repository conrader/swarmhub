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


/// A refusal with a reason: Grok answers the first request with 401 and says why. The sheet stops, says what Grok
/// said and that Grok Bot is newer than the checked version, and asks macOS only once.
@MainActor @Test func aRefusalOnTheFirstRequestStopsTheSheetWithWhatGrokSaid() async throws {
    let world = try GrokWorld()
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0)
    try plist.write(to: world.location.app.appending(path: "Contents/Info.plist"))
    let said = "Grok Bot requires an Ultra subscription or a Premium self-serve team seat"
    world.fake.intercept = { _, _ in .http(401, Array(#"{"code":"unauthenticated","message":"\#(said)"}"#.utf8)) }
    let store = world.store(server: "https://box.test/v1")
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    #expect(coordinator.versionDriftNote == "Grok Bot is 1.2.3; this import was last checked against 0.70.2.")
    await runFull(coordinator)
    guard case .failed(.server(let refusal)) = coordinator.step else {
        Issue.record("the sheet is at \(coordinator.step)")
        return
    }
    #expect(refusal.reason == .signInInvalid && refusal.serverMessage == said)
    #expect(coordinator.requests == 1 && world.passwords.reads == 1)
    #expect(coordinator.progress.allSatisfy { $0.status == .queued })
    try await render(coordinator, store, name: "refused")
}
