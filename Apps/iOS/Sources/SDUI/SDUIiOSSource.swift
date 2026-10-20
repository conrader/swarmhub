import SwiftUI
import SwarmHubCore

private struct SDUIViewSourceKey: EnvironmentKey { static let defaultValue = SDUIViewSource.compiledOnly }

extension EnvironmentValues {
    /// P7c: where server-driven views come from. The default has no documents, so every view is the compiled one.
    var sduiViewSource: SDUIViewSource {
        get { self[SDUIViewSourceKey.self] }
        set { self[SDUIViewSourceKey.self] = newValue }
    }
}

/// The iOS compiled SDUI policy and its reading of the installed bundle (P7c, CORE-PLAN.md §5.3, §5.4).
enum SDUIiOS {
    /// Hosts `open_url` may open, compiled into the app. Empty, as on the Mac: a document with a URL action is refused
    /// by the decoder and the compiled view is shown. Adding a host is an app build (and App Store review).
    static let urlHosts: Set<String> = []
    static let policy = SDUIPolicy(urlHosts: urlHosts)

    /// The documents of the bundle installed under `root` (the app container's Application Support by default), with
    /// that bundle's `kill.view.*` flags. Nothing installed, an unreadable store or no `ui` component: compiled only.
    /// Read once per launch; never fetches and never creates the store.
    static func installedSource(root: URL? = nil) -> SDUIViewSource {
        guard let root = root ?? (try? UpdateStore.defaultRoot()),
              FileManager.default.fileExists(atPath: root.path) else { return .compiledOnly }
        let updates = UpdateStore(root: root)
        return SDUIViewSource(updates: updates, config: ConfigStore(updates: updates), policy: policy)
    }

    static let installed = installedSource()
}
