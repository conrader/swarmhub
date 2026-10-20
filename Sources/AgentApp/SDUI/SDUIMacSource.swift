import SwiftUI
import SwarmHubCore

private struct SDUIViewSourceKey: EnvironmentKey { static let defaultValue = SDUIViewSource.compiledOnly }

extension EnvironmentValues {
    /// P7b: where server-driven views come from. The default has no documents, so every view is the compiled one.
    var sduiViewSource: SDUIViewSource {
        get { self[SDUIViewSourceKey.self] }
        set { self[SDUIViewSourceKey.self] = newValue }
    }
}

/// The Mac's compiled SDUI policy and its reading of the installed bundle (P7b, CORE-PLAN.md §5.3, §5.4).
enum SDUIMac {
    /// Hosts `open_url` may open, compiled into the app. Empty: a document with a URL action is refused by the decoder
    /// and the compiled view is shown. Adding a host is an app build (CORE-PLAN.md §5.2).
    static let urlHosts: Set<String> = []
    static let policy = SDUIPolicy(urlHosts: urlHosts)

    /// The documents of the bundle the update client installed under `root` (Application Support by default), with
    /// that bundle's `kill.view.*` flags. Nothing installed, an unreadable store or no `ui` component: compiled only.
    /// Read once per launch; never fetches.
    static func installedSource(root: URL? = nil) -> SDUIViewSource {
        guard let root = root ?? (try? UpdateStore.defaultRoot()) else { return .compiledOnly }
        let updates = UpdateStore(root: root)
        return SDUIViewSource(updates: updates, config: ConfigStore(updates: updates), policy: policy)
    }

    static let installed = installedSource()
}
