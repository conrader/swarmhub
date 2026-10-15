import AppKit
import SwiftUI

/// P36 shots of `--render-setup`: the Reports inbox with an agent bug, an agent feature request and Konrad's own report,
/// the editable detail, Send with no account (P40: the app has no sign-in), a sent report with status "planned" and
/// SwarmHub's note, Settings → Account (the service address only), and the sidebar's Reports row. In-memory store and key store; no network, no Keychain.
@MainActor enum HeadlessP36Shots {
    static let names = ["p36-reports-inbox", "p36-report-detail", "p36-send-signed-out", "p36-sent-planned", "p36-account-signed-out",
                         "p36-sidebar-reports"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
        let cfo = Bot(name: "Cfo", backend: .hermes, hermesProfile: "cfo")
        store.bots = [jarvis, cfo]; store.selectedBot = jarvis
        let box = store.connection(of: cfo), now = Date()
        let bug = SwarmReport(id: "r20261015T101500Z-ab12cd34", source: .agent, kind: .bug, title: "bot-msg to Jarvis times out after 5 minutes",
                              body: "I ran `bot-msg --from cfo --to grok-jarvis` twice for the monthly budget summary. Both times it exited 124 after 300 s; Jarvis answered in its thread later.\n\nExpected: the reply within the wait, or a way to wait longer from the skill.",
                              bot: "cfo", connection: box, botBackend: "hermes", skillVersions: ["swarmhub-coding": "1.2.0", "swarmhub-feedback": "1.0.0", "swarmhub-messages": "1.0.0"],
                              hermesVersion: "0.22.0", createdAt: now.addingTimeInterval(-8 * 60), boxFile: .present)
        let wish = SwarmReport(id: "r20261015T094000Z-77aa0011", source: .agent, kind: .feature, title: "Let me attach a file when I message another bot",
                               body: "Konrad asked me to pass the invoice PDF to Cfo. bot-msg sends text only, so I pasted a summary instead.", bot: "grok-jarvis", connection: box,
                               botBackend: "hermes", skillVersions: ["swarmhub-feedback": "1.0.0", "swarmhub-messages": "1.0.0"], createdAt: now.addingTimeInterval(-52 * 60), boxFile: .present)
        var mine = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: ["Hermes"], now: now.addingTimeInterval(-3 * 3600))
        mine.title = "Settings window opens behind the main window"
        let center = store.reportsCenter
        center.inbox = ReportsInbox(reports: [bug, wish, mine]); center.selectedID = bug.id
        center.account = .signedIn(expires: now.addingTimeInterval(29 * 86_400))
        store.showingReports = true
        let inboxSize = NSSize(width: 980, height: 620)
        write(names[0], await png(AnyView(ReportsInboxView(center: center).frame(width: inboxSize.width, height: inboxSize.height)), store, inboxSize))
        let detailSize = NSSize(width: 660, height: 620)
        write(names[1], await png(AnyView(ReportDetailView(center: center, report: bug).frame(width: detailSize.width, height: detailSize.height).background(AppColor.chat)), store, detailSize))

        center.account = .signedOut
        let prompt = ReportDetailView(center: center, report: wish).frame(width: detailSize.width, height: 560).background(AppColor.chat)
        write(names[2], await png(AnyView(prompt), store, NSSize(width: detailSize.width, height: 560)))

        var sent = bug
        sent.state = .sent; sent.serverID = "42"; sent.status = "planned"; sent.boxFile = .closed; sent.updatedAt = now
        sent.note = "Thanks — the wait limit becomes a setting in 0.6, and bot-msg will say the answer is still coming."
        center.inbox = ReportsInbox(reports: [sent, wish, mine]); center.selectedID = sent.id; center.account = .signedIn(expires: now.addingTimeInterval(29 * 86_400))
        write(names[3], await png(AnyView(ReportsInboxView(center: center).frame(width: inboxSize.width, height: inboxSize.height)), store, inboxSize))

        center.account = .signedOut
        write(names[4], await png(AnyView(Form { SettingsSwarmHubAccountPane(center: center) }.formStyle(.grouped).frame(width: 560, height: 300).background(AppColor.panel)), store, NSSize(width: 560, height: 300)))

        center.inbox = ReportsInbox(reports: [bug, wish, mine]); store.showingReports = false
        let column = SidebarView(selection: .constant(jarvis)).frame(width: SidebarMetrics.width.ideal, height: 420)
        write(names[5], await png(AnyView(column), store, NSSize(width: SidebarMetrics.width.ideal, height: 420)))

    }
}
