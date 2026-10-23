import AppKit
import SwiftUI

/// Off-app alerts shots of `--render-setup` (alone with `--only alerts`): one server's section with ntfy and email on
/// and the box's service running, and a server not set up yet. Synthetic and in memory: nothing is sent.
@MainActor enum HeadlessAlertsShots {
    static let names = ["alerts-running", "alerts-not-set-up"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false; store.webhooks.autoLoad = false
        let reporter = Bot(name: "Reporter", title: "Nightly numbers", backend: .hermes, hermesProfile: "grok-reporter")
        reporter.avatarName = .robot; reporter.hermesBaseURL = "https://my-box.example.com/p/grok-reporter/v1"
        store.bots = [reporter]
        let target = store.connection(of: reporter), host = URL(string: target)?.host ?? target
        var settings = AlertSettings()
        settings.ntfyURL = "https://ntfy.sh/swarm-hub-alerts"
        settings.emailOn = true; settings.emailHost = "smtp.example.com"; settings.emailUser = "me@example.com"
        settings.emailFrom = "box@example.com"; settings.emailTo = "me@example.com"
        let now = Date.now.timeIntervalSince1970
        func panel(configured: Bool) -> BoxAlertsPanel {
            BoxAlertsPanel(schema: BoxAlertsPanel.schemaID, action: "status", result: nil,
                           config: .init(configured: configured, enabled: configured, window: true, sinks: configured ? ["ntfy", "email"] : []),
                           service: .init(manager: "systemd", installed: configured, service: configured ? "active" : "not installed", running: configured,
                                          detail: configured ? "Running." : "The alert service is not installed on this box. Save the settings to start it.",
                                          logs: "journalctl --user -u swarmhub-alerts.service", lastError: nil, lastErrorAt: nil,
                                          lastSentAt: configured ? now - 420 : nil, presenceUntil: configured ? now + 240 : nil, pending: 0),
                           boxKey: "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw")
        }
        let size = NSSize(width: 620, height: 820)
        func shot(_ name: String, configured: Bool) async {
            store.defaults.set(try? JSONEncoder().encode(configured ? settings : AlertSettings()), forKey: "alerts.settings." + target)
            store.boxAlerts.update(target) { $0.panel = panel(configured: configured); $0.notice = configured ? AlertsCopy.testResult(["ntfy": "sent", "email": "sent"]) : nil }
            write(name, await png(AnyView(Form {
                Section(AlertsCopy.title) {
                    Text(AlertsCopy.caption).font(.caption).foregroundStyle(.secondary)
                    BoxAlertsServerView(target: target, host: host, cache: store.boxAlerts, expanded: true)
                    Text(AlertsCopy.presenceNote).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(width: size.width, height: size.height).background(AppColor.panel)), store, size))
        }
        await shot(names[0], configured: true)
        await shot(names[1], configured: false)
    }
}
