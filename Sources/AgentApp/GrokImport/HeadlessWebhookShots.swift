import AppKit
import SwiftUI

/// Webhooks shots of `--render-setup` (alone with `--only webhooks`): the Routines tab's Webhooks section with the
/// receiver running and two routines, the receiver down on a box, and the one-time key sheet. All synthetic and in
/// memory: nothing is sent and the key is a placeholder.
@MainActor enum HeadlessWebhookShots {
    static let names = ["webhooks-running", "webhooks-receiver-down", "webhooks-key-once"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false; store.webhooks.autoLoad = false
        let reporter = Bot(name: "Reporter", title: "Nightly numbers", backend: .hermes, hermesProfile: "grok-reporter")
        reporter.avatarName = .robot; reporter.hermesBaseURL = "https://my-box.example.com/p/grok-reporter/v1"
        store.bots = [reporter]
        store.routines.update(reporter.id) { $0.jobs = .loaded([]) }
        let base = "http://127.0.0.1:8745/swarmhub/webhook/grok-reporter/"
        let now = Date.now.timeIntervalSince1970
        let hooks = [BoxWebhook(profile: "grok-reporter", routine: "github-push", url: base + "github-push/Qm3xZ0aK7pW1rT9uY2cV", created: now - 86_400 * 3,
                                rotated: now - 7_200, fired: 14),
                     BoxWebhook(profile: "grok-reporter", routine: "nightly-report", url: base + "nightly-report/Hx8Lk2Pq9Vn4Bt6Wy1Zs", created: now - 3_600,
                                rotated: now - 3_600, fired: 0)]
        func receiver(_ running: Bool) -> WebhookReceiverStatus {
            .init(manager: "systemd", installed: running, service: running ? "active" : "not installed", running: running, listen: "127.0.0.1:8745",
                  logs: "journalctl --user -u swarmhub-webhook.service",
                  detail: running ? "Receiving on 127.0.0.1:8745." : "The receiver is not installed on this box. Start it from the app or run `swarmctl webhook receiver install`.")
        }
        let size = NSSize(width: 340, height: 640)
        func shot(_ name: String, running: Bool) async {
            store.webhooks.update(reporter.id) {
                $0.panel = WebhookPanel(schema: WebhookPanel.schemaID, profile: "grok-reporter", action: "list", result: nil, webhooks: hooks, receiver: receiver(running))
            }
            write(name, await png(AnyView(ScrollView { RoutinesView(bot: reporter, cache: store.routines).padding(14) }
                .frame(width: size.width, height: size.height).background(AppColor.panel)), store, size))
        }
        await shot(names[0], running: true)
        await shot(names[1], running: false)
        let reveal = WebhookReveal(routine: "nightly-report", url: hooks[1].url, key: "SYNTHETIC-placeholder-key-not-a-real-secret-0", rotated: false)
        let sheet = NSSize(width: 460, height: 420)
        write(names[2], await png(AnyView(VStack(alignment: .leading, spacing: 14) {
            WebhookRevealView(reveal: reveal)
            HStack { Spacer(); Button(WebhookCopy.done) {} }
        }.padding(20).frame(width: sheet.width, height: sheet.height, alignment: .top).background(AppColor.panel)), store, sheet))
    }
}
