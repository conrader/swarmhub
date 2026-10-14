import AppKit
import SwiftUI

/// The right-panel shots of `--render-setup` (P21b item 6): the Model tab, the routine editor and the group panel, each
/// folded and with Advanced open. P33: every tab of a Hermes agent and of an OpenClaw agent at the panel's minimum and
/// maximum widths, and the tab bar in both compact styles. Every value is synthetic and set in memory (the model list is built here, nothing is
/// loaded: the store's caches never fetch); no network, no Keychain.
@MainActor enum HeadlessInspector {
    static let panelSize = NSSize(width: 360, height: 900)
    static let editorSize = NSSize(width: 470, height: 560)
    static let widths: [CGFloat] = [300, 380]
    /// What a fresh OpenClaw agent shows (no imported skills, audit or local routines).
    static let openClawTabs: [AgentInfoTab] = [.overview, .model, .media, .computer]
    static let tabNames = widths.flatMap { width in
        AgentInfoTab.allCases.map { "tab-hermes-\($0.rawValue.lowercased())-\(Int(width))" } + openClawTabs.map { "tab-openclaw-\($0.rawValue.lowercased())-\(Int(width))" }
    }
    static let barNames = widths.flatMap { width in ["tabbar-caption-\(Int(width))", "tabbar-symbols-\(Int(width))"] }
    static let names = ["inspector-folded", "inspector-advanced", "routine-simple", "routine-advanced", "group-folded", "group-advanced"] + tabNames + barNames

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
        store.infoTab = .model
        for (name, open) in [("inspector-folded", false), ("inspector-advanced", true)] {
            write(name, await png(AnyView(InfoPanel(bot: agent).environment(\.inspectorStartsAdvanced, open)), panelSize))
        }
        await renderTabs(store: store, agent: agent, write: write, png: png)
        write("routine-simple", await png(AnyView(RoutineEditorSheet(bot: agent, job: nil, schedule: "30 8 * * 1-5")), editorSize))
        write("routine-advanced", await png(AnyView(RoutineEditorSheet(bot: agent, job: nil, schedule: "*/15 9-17 * * 1-5")), editorSize))
        var members = agents.prefix(2).map(\.id)
        if members.count < 2 { let extra = Bot(name: "Writer", backend: .hermes, hermesProfile: "writer"); store.bots.append(extra); members.append(extra.id) }
        guard let group = store.createGroup(name: "", memberIDs: members) else { write("group-folded", nil); write("group-advanced", nil); return }
        for (name, open) in [("group-folded", false), ("group-advanced", true)] {
            write(name, await png(AnyView(GroupInfoPanel(group: group).environment(\.inspectorStartsAdvanced, open)), panelSize))
        }
    }

    /// P33: every tab per agent and width. The Hermes agent gets one approval decision and one waiting approval so
    /// Activity and Overview's pointer have something to show.
    private static func renderTabs(store: AppStore, agent: Bot, write: (String, Data?) -> Void, png: (AnyView, NSSize) async -> Data?) async {
        if agent.approvalAudit.isEmpty {
            agent.approvalAudit.append(ApprovalAuditEntry(approvalID: UUID(), actionKind: "terminal", outcome: .approved, decidedBy: "You", reason: "Listed the reports folder"))
        }
        let waiting = ApprovalRequest(id: UUID(), title: "Approve", summary: "Run a command", draft: nil, botID: agent.id)
        store.approvals.append(waiting)
        defer { store.approvals.removeAll { $0.id == waiting.id } }
        let claw = store.bots.first { $0.backend == .openClaw } ?? Bot(name: "Alpha", backend: .openClaw)
        let previous = store.infoTab
        defer { store.infoTab = previous }
        for width in widths {
            let size = NSSize(width: width, height: panelSize.height)
            for (slug, bot) in [("hermes", agent), ("openclaw", claw)] {
                let tabs = slug == "hermes" ? AgentInfoTab.allCases : openClawTabs
                for tab in tabs {
                    store.infoTab = tab
                    write("tab-\(slug)-\(tab.rawValue.lowercased())-\(Int(width))", await png(AnyView(InfoPanel(bot: bot).frame(width: width)), size))
                }
            }
            store.infoTab = .overview
            for (style, name) in [(InfoTabBar.Style.symbolCaption, "caption"), (.symbolOnly, "symbols")] {
                let bar = InfoTabBar(tabs: AgentInfoTab.allCases, selection: .overview, style: style) { _ in }.frame(width: width)
                write("tabbar-\(name)-\(Int(width))", await png(AnyView(bar), NSSize(width: width, height: 52)))
            }
        }
    }
}
