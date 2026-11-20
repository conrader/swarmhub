import Foundation
import Testing

// The AgentApp target uses path "."; a packaged dist/SwarmHub.app must not leak its Sparkle nibs/lproj into the target's resources.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func appTargetExcludesBuildOutputFolders() throws {
    let manifest = try String(contentsOf: repoRoot.appending(path: "Package.swift"), encoding: .utf8)
    let excludeLine = try #require(manifest.split(separator: "\n").first { $0.contains("exclude: [") })
    for folder in ["dist"] {
        #expect(excludeLine.contains("\"\(folder)\""), "Package.swift exclude lacks \(folder)")
    }
}

@Test func packageScriptWritesOnlyIntoExcludedFolders() throws {
    let script = try String(contentsOf: repoRoot.appending(path: "scripts/package-release.sh"), encoding: .utf8)
    #expect(script.contains("APP_DIR=\"$STAGING/$APP_NAME.app\""))
    #expect(script.contains("ARCHIVE_DIR=\"$ROOT_DIR/dist\""))
    #expect(script.contains("trap cleanup EXIT"))
    #expect(script.contains("unregister_app \"$APP_DIR\""))
}
