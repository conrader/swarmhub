import AppKit
import SwiftUI

/// The right-panel shots of `--render-setup` (P21b item 6): the Overview, the routine editor and the group panel, each
/// folded and with Advanced open. Every value is synthetic and set in memory (the model list is built here, nothing is
/// loaded: the store's caches never fetch); no network, no Keychain.
@MainActor enum HeadlessInspector {
    static let panelSize = NSSize(width: 360, height: 900)
    static let editorSize = NSSize(width: 470, height: 560)
    static let names = ["inspector-folded", "inspector-advanced", "routine-simple", "routine-advanced", "group-folded", "group-advanced"]

    /// A two-supplier list in the shape Hermes reports, with neutral names of our own.
    static func sampleInfo() -> BotServerInfo {
        let payload: [String: Any] = ["model": "sample-large", "provider": "sample-cloud", "providers": [
            ["slug": "sample-cloud", "name": "Sample Cloud", "is_current": true, "models": ["sample-large", "sample-small"], "authenticated": true, "source": "built-in"],
            ["slug": "sample-local", "name": "Sample Local", "is_current": false, "models": ["sample-local-1"], "authenticated": true, "source": "local-runtime"],
        ]]
        var info = BotServerInfo(capabilities: HermesCapabilities(), skills: .loaded([]), toolsets: .loaded([]),
                                 modelOptions: .loaded(HermesModelOptions.parse(payload)))
        info.isRefreshing = false
        return info
    }

    static func render(store: AppStore, write: (String, Data?) -> Void, png: (AnyView, NSSize) async -> Data?) async {
        let agents = store.bots.filter { $0.backend == .hermes && !$0.isDemo }
        guard let agent = agents.first else { for name in names { write(name, nil) }; return }
        store.botInfo.replace(botID: agent.id, with: sampleInfo())
        store.infoTab = .overview
        for (name, open) in [("inspector-folded", false), ("inspector-advanced", true)] {
            write(name, await png(AnyView(InfoPanel(bot: agent).environment(\.inspectorStartsAdvanced, open)), panelSize))
        }
        write("routine-simple", await png(AnyView(RoutineEditorSheet(bot: agent, job: nil, schedule: "30 8 * * 1-5")), editorSize))
        write("routine-advanced", await png(AnyView(RoutineEditorSheet(bot: agent, job: nil, schedule: "*/15 9-17 * * 1-5")), editorSize))
        var members = agents.prefix(2).map(\.id)
        if members.count < 2 { let extra = Bot(name: "Writer", backend: .hermes, hermesProfile: "writer"); store.bots.append(extra); members.append(extra.id) }
        guard let group = store.createGroup(name: "", memberIDs: members) else { write("group-folded", nil); write("group-advanced", nil); return }
        for (name, open) in [("group-folded", false), ("group-advanced", true)] {
            write(name, await png(AnyView(GroupInfoPanel(group: group).environment(\.inspectorStartsAdvanced, open)), panelSize))
        }
    }
}
