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

@MainActor @Test(renderTestsOnly) func everyStepOfTheImportSheetRenders() async throws {
    let world = try GrokWorld()
    let store = world.store(server: "https://box.test/v1")
    let found = makeCoordinator(world, store)
    await found.scan()
    try await render(found, store, name: "1-found")
    found.mode = .recent
    try await render(found, store, name: "1b-found-recent")

    let permission = makeCoordinator(world, store)
    await permission.scan()
    await permission.proceed()
    permission.signInMayBeStale = true
    try await render(permission, store, name: "2-permission")
    permission.step = .awaitingMacOS(since: Date())
    permission.elapsedSeconds = 12
    try await render(permission, store, name: "3-awaiting-macos")
    permission.step = .failed(.keychain(.denied(errSecAuthFailed)))
    try await render(permission, store, name: "4-denied")
    permission.step = .paused(.tokenExpired)
    permission.holdsSignIn = true
    try await render(permission, store, name: "5-expired")

    let running = makeCoordinator(world, store)
    await running.scan()
    running.progress = running.items.map { GrokProgressRow(id: $0.id, name: $0.name, isGroup: $0.isGroup, newestSeq: 1200) }
    running.progress[0].status = .done
    running.progress[1].status = .fetching
    running.progress[1].pages = 2
    running.progress[1].oldestSeq = 201
    running.step = .running
    running.requests = 4
    running.elapsedSeconds = 3
    try await render(running, store, name: "6-importing")
    running.progress[1].status = .paused
    running.step = .paused(.network(GrokServerError(.network, kind: .list, errorType: "URLError")))
    try await render(running, store, name: "7-paused-network")
    running.step = .failed(.server(GrokServerError(.protocolChanged, kind: .list, httpStatus: 200)))
    running.progress[1].status = .failed("Grok's service answered in a format SwarmHub does not know.")
    try await render(running, store, name: "8-stopped")

    let done = makeCoordinator(world, store)
    await done.scan()
    await runFull(done)
    #expect(done.step == .finished)
    done.outcomes[0].connection = .live
    done.outcomes[2].connection = .profileNotOnServer
    try await render(done, store, name: "9-done")
    done.step = .cancelled
    try await render(done, store, name: "9b-cancelled")

    let unavailable = makeCoordinator(world, store)
    await unavailable.scan()
    unavailable.availability = .unavailable(.cache(.needsAccountChoice(accounts: 2)))
    try await render(unavailable, store, name: "0-unavailable")
    #expect(world.passwords.reads == 1)
}
