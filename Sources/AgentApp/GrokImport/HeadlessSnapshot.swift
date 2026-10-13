import AppKit
import Security
import SwiftUI

/// `AgentApp --render-snapshot <dir> [--bot "<name>"]...` renders the real UI from the saved store without
/// showing a window: `main.png` (first Grok bot selected), and per bot `<slug>.png` (Grok history expanded)
/// plus `info-<slug>.png` (its right panel). Dark, 1280×800 points at scale 2. Nothing is saved to the store.
@MainActor enum HeadlessSnapshot {
    static let size = NSSize(width: 1280, height: 800)
    static let infoSize = NSSize(width: 360, height: 800)

    static func run(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--render-snapshot"), arguments.indices.contains(flag + 1) else {
            print("Usage: AgentApp --render-snapshot <dir> [--bot \"<name>\"]..."); return 64
        }
        var names: [String] = []
        for (index, argument) in arguments.enumerated() where argument == "--bot" {
            guard arguments.indices.contains(index + 1) else { print("--bot needs a name"); return 64 }
            names.append(arguments[index + 1])
        }
        let directory = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath, isDirectory: true)
        // Same store location and decoding as the app; no Hermes refresh, so nothing goes over the network.
        SecKeychainSetUserInteractionAllowed(false)
        let store = AppStore(autoConfigureHermes: false)
        var code: Int32?
        Task { @MainActor in code = await render(store: store, to: directory, botNames: names, output: { print($0); fflush(stdout) }) }
        while code == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        return code!
    }

    static func render(store: AppStore, to directory: URL, botNames: [String], output: (String) -> Void) async -> Int32 {
        if let repo = enclosingRepository(of: directory) { output("Refused: \(directory.path) is inside the repository \(repo.path)."); return 2 }
        var bots: [Bot] = []
        for name in botNames {
            guard let bot = store.bots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { output("No bot named \(name)."); return 2 }
            bots.append(bot)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { output("Cannot create \(directory.path): \(error.localizedDescription)"); return 1 }

        let previousSelection = store.selectedBot, previousInfo = store.showInfo
        defer { store.selectedBot = previousSelection; store.showInfo = previousInfo }
        store.showInfo = true
        let firstGrokBot = store.bots.first { $0.grokSourceID != nil && !$0.isReadOnlyArchive && !$0.isHidden } ?? store.bots.first
        var shots: [(file: String, selected: Bot?, render: () async -> Data?)] = [("main.png", firstGrokBot, { await SnapshotRenderer.contentPNG(store: store, size: size) })]
        for bot in bots {
            shots.append(("\(slug(bot.name)).png", bot, { await SnapshotRenderer.contentPNG(store: store, size: size, historyExpanded: true) }))
            shots.append(("info-\(slug(bot.name)).png", bot, { await SnapshotRenderer.png(InfoPanel(bot: bot).environmentObject(store), size: infoSize) }))
        }
        var failures = 0
        for shot in shots {
            store.selectedBot = shot.selected
            let url = directory.appending(path: shot.file)
            guard let data = await shot.render(), let image = NSBitmapImageRep(data: data) else { output("\(url.path): render failed"); failures += 1; continue }
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                output("\(url.path) \(image.pixelsWide)x\(image.pixelsHigh) \(data.count) bytes")
            } catch { output("\(url.path): \(error.localizedDescription)"); failures += 1 }
        }
        return failures == 0 ? 0 : 1
    }

    static func slug(_ name: String) -> String {
        let parts = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return parts.isEmpty ? "bot" : parts.joined(separator: "-")
    }

    /// Nearest ancestor (or the directory itself) that holds a `.git` entry.
    static func enclosingRepository(of directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL.resolvingSymlinksInPath()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appending(path: ".git").path) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }
}
