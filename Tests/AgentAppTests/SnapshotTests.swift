import AppKit
import Foundation
import Testing
@testable import AgentApp

private let exportFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/bundles/export").standardizedFileURL

/// Distinct colours on a coarse grid; a blank or placeholder render has only one or two.
private func distinctColours(_ image: NSBitmapImageRep) -> Int {
    var seen = Set<String>()
    for x in stride(from: 0, to: image.pixelsWide, by: 16) { for y in stride(from: 0, to: image.pixelsHigh, by: 16) {
        if let c = image.colorAt(x: x, y: y) { seen.insert(String(format: "%.2f%.2f%.2f", c.redComponent, c.greenComponent, c.blueComponent)) }
    } }
    return seen.count
}

@MainActor @Test func renderSnapshotWritesNonEmptyPNGsForSyntheticStore() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "synthetic"]), defaults: isolatedDefaults())
    try store.importGrokExport(at: exportFolder)
    let storeBefore = try Data(contentsOf: store.fileURL)
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppSnapshots-\(UUID().uuidString)")
    var lines: [String] = []
    #expect(await HeadlessSnapshot.render(store: store, to: directory, botNames: ["jarvis", "Finance Controller"], output: { lines.append($0) }) == 0)
    let expected = ["main.png": (2560, 1600), "sidebar.png": (560, 1600), "jarvis.png": (2560, 1600), "info-jarvis.png": (720, 1600),
                    "finance-controller.png": (2560, 1600), "info-finance-controller.png": (720, 1600)]
    for (file, size) in expected {
        let data = try Data(contentsOf: directory.appending(path: file))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == size.0 && image.pixelsHigh == size.1, "\(file)")
        #expect(distinctColours(image) > 8, "\(file) looks blank")
    }
    #expect(lines.count == expected.count)
    // The sidebar (glass column) must be the dark sidebar with rows, not a blank sheet.
    let main = try #require(NSBitmapImageRep(data: Data(contentsOf: directory.appending(path: "main.png"))))
    let sidebarBackground = try #require(main.colorAt(x: 200, y: 1200)?.usingColorSpace(.sRGB))
    #expect(sidebarBackground.brightnessComponent < 0.2)
    let sidebar = try #require(main.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 1600)))
    #expect(distinctColours(NSBitmapImageRep(cgImage: sidebar)) > 8)
    #expect(try Data(contentsOf: directory.appending(path: "jarvis.png")) != Data(contentsOf: directory.appending(path: "main.png")))
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    #expect(try Data(contentsOf: store.fileURL) == storeBefore)
}

@MainActor @Test func renderSnapshotRefusesUnknownBotAndRepositoryDirectory() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let outside = FileManager.default.temporaryDirectory.appending(path: "AgentAppSnapshots-\(UUID().uuidString)")
    #expect(await HeadlessSnapshot.render(store: store, to: outside, botNames: ["Nobody"], output: { _ in }) == 2)
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..").standardizedFileURL
    let inside = repoRoot.appending(path: "snapshots-should-not-exist")
    #expect(await HeadlessSnapshot.render(store: store, to: inside, botNames: [], output: { _ in }) == 2)
    #expect(!FileManager.default.fileExists(atPath: inside.path))
    #expect(HeadlessSnapshot.slug("Konrad, Jarvis & Co") == "konrad-jarvis-co")
}
