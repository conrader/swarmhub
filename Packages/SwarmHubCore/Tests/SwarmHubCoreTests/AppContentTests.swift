import Foundation
import Testing
@testable import SwarmHubCore

// Build a real TEST-signed baseline with the existing offline harness. No fixture bytes are rewritten.
// These tests run via swift test on the Mac; AppContent itself also compiles into the iOS app.
#if os(macOS)
private func contentApp(at root: URL, target: AppContent.Target, embed: Bool = true) throws -> Bundle {
    let app = root.appending(path: "SwarmHub.app")
    let resources = app.appending(path: "Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist = ["CFBundleIdentifier": "test.p2c.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
    if embed {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", repo.appending(path: "scripts/release/baseline.py").path,
                             "embed", "--configuration", "debug", "--out", resources.path] + (target == .ios ? ["--ios"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let log = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: log, as: UTF8.self))")
    }
    return try #require(Bundle(url: app))
}

private func contentRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "AppContentP2c-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test(arguments: [AppContent.Target.mac, .ios])
func firstLaunchWithoutFetchedStoreConsumesVerifiedBaseline(target: AppContent.Target) throws {
    let root = try contentRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try contentApp(at: root, target: target)
    let content = AppContent.resolve(in: bundle, target: target)
    let baseline = try #require(content.baseline)
    #expect(baseline.bundleVersion == 1 && baseline.label == "baseline")
    #expect(Set(content.archives.keys) == Set(baseline.components(for: target.rawValue).map(\.name)))
    let policy = try #require(content.archives["policy"])
    #expect(policy.range(of: Data("swarmhub/config-policy/1".utf8)) != nil)
    #expect(!content.archives.keys.contains("swarmhub-coding"))
    #expect(content.archives["manager-prompts"] != nil || target == .ios)
}

@Test(arguments: [AppContent.Target.mac, .ios])
func unreachableUpdateHostChangesNoContent(target: AppContent.Target) throws {
    let root = try contentRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try contentApp(at: root, target: target)
    let offline = AppContent.resolve(in: bundle, target: target)
    #expect(offline.baseline != nil)
    var attempts = 0
    let unreachable = AppContent.resolve(in: bundle, target: target, fetchedStore: {
        attempts += 1
        throw URLError(.cannotConnectToHost)
    })
    #expect(attempts == 1)
    #expect(unreachable == offline)
}

@Test(arguments: [AppContent.Target.mac, .ios])
func tamperedBaselineIsNotConsumed(target: AppContent.Target) throws {
    let root = try contentRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try contentApp(at: root, target: target)
    let original = AppContent.resolve(in: bundle, target: target)
    let baseline = try #require(original.baseline)
    let policy = try #require(baseline.components.first { $0.name == "policy" })
    try Data("tampered".utf8).write(to: baseline.directory.appending(path: "blobs/sha256/\(policy.sha256)"))
    let content = AppContent.resolve(in: bundle, target: target)
    #expect(content.baseline == nil && content.archives.isEmpty)
}

@Test func absentEmbeddedBaselineDoesNotUseAdjacentResources() throws {
    let root = try contentRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try contentApp(at: root.appending(path: "empty"), target: .mac, embed: false)
    let other = try contentApp(at: root.appending(path: "other"), target: .mac)
    let outside = try #require(other.resourceURL).appending(path: "Baseline")
    let adjacent = root.appending(path: "empty/AgentApp.resources/Baseline")
    try FileManager.default.createDirectory(at: adjacent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: outside, to: adjacent)
    let missing = AppContent.resolve(in: bundle, target: .mac)
    #expect(missing.baseline == nil && missing.archives.isEmpty)
    let link = try #require(bundle.resourceURL).appending(path: "Baseline")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let linked = AppContent.resolve(in: bundle, target: .mac)
    #expect(linked.baseline == nil && linked.archives.isEmpty)
}
#endif
