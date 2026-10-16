#if DEBUG
import SwiftUI

/// Uses real AppStore messages and the app's actual message renderer. The tester's only mutation interface is the
/// closed controller; settings/import/voice/computer/account editors have no entrypoint in this scene.
struct QAWorkspace: View {
    @ObservedObject var controller: QAController
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            Text("[QA-TEST] QA TEST MODE · outbound tools record only").bold().padding(10).frame(maxWidth: .infinity).background(.orange)
            Text(controller.status).font(.caption).textSelection(.enabled).padding(6)
            NavigationSplitView {
                List(store.bots) { bot in
                    Button(bot.name) { store.selectedBot = bot }.buttonStyle(.plain)
                }
            } detail: {
                if let bot = store.selectedBot { QATranscript(bot: bot) }
                else { Text("[QA-TEST] No QA chats. Waiting for the local tester.") }
            }
            ForEach(store.approvals) { approval in
                Text("[QA-TEST] Waiting for tester decision: \(approval.title)").font(.caption).padding(6)
            }
        }.environmentObject(store).defaultAppStorage(store.defaults)
    }
}
private struct QATranscript: View {
    @ObservedObject var bot: Bot
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text(bot.name).font(.title2).padding()
                ForEach(bot.messages) { message in
                    MessageView(message: message).disabled(true).allowsHitTesting(false)
                }
            }
        }
    }
}
#endif
