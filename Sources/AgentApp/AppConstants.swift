import Foundation

/// The app's visible name lives here and in `Resources/Info.plist` (a test keeps them equal). A rename changes these
/// two places; the internal codename `AgentApp`, the bundle id, the data folder and the Keychain service stay.
enum AppConstants {
    static let name = "SwarmHub"
    /// The name before P18 (2026-10-13). Only read for folders and session prefixes that older builds wrote.
    static let previousName = "Torvli"

    /// The honest user-agent sent to Grok and GitHub: `SwarmHub/<version>`.
    static func userAgent(version: String) -> String { "\(name)/\(version)" }

    /// GitHub repository for Settings → Updates. Before the repo rename `previousReleasesRepo` is the one that exists;
    /// after it GitHub redirects the old name, so the checker tries the new name first and falls back on 404.
    static let releasesRepo = "conrader/\(name.lowercased())"
    static let previousReleasesRepo = "conrader/\(previousName.lowercased())"

    /// `~/Documents/SwarmHub Grok Export`; the old `~/Documents/Torvli Grok Export` while the new one does not exist.
    static func grokExportFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
        let current = documents.appending(path: "\(name) Grok Export", directoryHint: .isDirectory)
        let previous = documents.appending(path: "\(previousName) Grok Export", directoryHint: .isDirectory)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        return !exists(current) && exists(previous) ? previous : current
    }
}
