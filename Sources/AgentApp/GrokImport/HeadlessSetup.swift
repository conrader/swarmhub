import AppKit
import SwiftUI

/// `AgentApp --render-setup <dir>`: renders the setup wizard's steps, the Settings pages, an agent's settings, the
/// chat the wizard ends in, the empty state and the line about removed bots to PNG (`HeadlessHerdrShots`). Everything comes from a synthetic
/// in-memory store, key store and settings suite, and Test results are built in memory: no network, no Keychain,
/// nothing of the real app is read or written. Refuses a directory inside the repository, like `--render-snapshot`.
@MainActor enum HeadlessSetup {
    static let size: NSSize = SetupView.size
    static let settingsSize = NSSize(width: 760, height: 560)
    /// `--light` renders every shot in the light appearance; dark is the app's default.
    static var scheme = ColorScheme.dark

    static func run(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--render-setup"), arguments.indices.contains(flag + 1) else {
            print("Usage: AgentApp --render-setup <dir>"); return 64
        }
        let directory = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath, isDirectory: true)
        scheme = arguments.contains("--light") ? .light : .dark
        return HeadlessRunLoop.wait { await render(to: directory, output: { print($0); fflush(stdout) }) }
    }

    static func render(to directory: URL, output: (String) -> Void) async -> Int32 {
        if let repo = HeadlessSnapshot.enclosingRepository(of: directory) { output("Refused: \(directory.path) is inside the repository \(repo.path)."); return 2 }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { output("Cannot create \(directory.path): \(error.localizedDescription)"); return 1 }
        let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
        var failures = 0
        func write(_ name: String, _ data: Data?) {
            let file = directory.appending(path: "\(name).png")
            if let data, (try? data.write(to: file)) != nil { output("\(file.path) \(data.count) bytes") } else { failures += 1; output("Failed: \(name)") }
        }
        await HeadlessHerdrShots.render(write: write) { view, shotStore, size in await png(view, store: shotStore, updater: updater, size: size) }
        let empty = SetupPreview.makeStore(); empty.isSetupPreview = false
        write("empty-state", await png(SetupEmptyState().frame(width: 700, height: 560).background(AppColor.chat), store: empty, updater: updater, size: settingsSize))
        // The line a person sees once, after a store of an older version was opened and its old bots were removed.
        let noticed = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); noticed.isSetupPreview = false
        noticed.legacyNotice = LegacyStore.notice(removed: 18, backup: URL(fileURLWithPath: "/Users/you/Library/Application Support/AgentApp/store.json.before-herdr-only-2026-11-17T09-00-00Z"))
        write("legacy-notice", await SnapshotRenderer.contentPNG(store: noticed, size: NSSize(width: 1100, height: 520), scheme: scheme))
        output("Rendered setup to \(directory.path); \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    static func png<V: View>(_ view: V, store: AppStore, updater: AppUpdater, size: NSSize, scheme: ColorScheme? = nil) async -> Data? {
        await SnapshotRenderer.png(view.environmentObject(store).environmentObject(updater).defaultAppStorage(store.defaults), size: size, scheme: scheme ?? Self.scheme)
    }
}
