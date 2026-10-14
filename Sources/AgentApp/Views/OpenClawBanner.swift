import SwiftUI

/// P12: above an OpenClaw bot's composer. Unbound, waiting for approval, failed or read-only: a banner with the next
/// action and no composer. Connecting: a quiet line, and a send waits up to 30 s. Otherwise just the composer.
struct OpenClawChatGate<Composer: View>: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var status: OpenClawStatus
    @ObservedObject var bot: Bot
    @ViewBuilder let composer: () -> Composer

    var body: some View {
        if let blocked = store.openClawBlock(bot) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(blocked).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if bot.openClaw != nil, store.gateway(id: bot.openClaw?.gatewayID) != nil { Button("Retry") { store.retryOpenClaw(bot) } }
                Button(SimpleCopy.agentSettings) { store.editingBot = bot }
            }
            .padding(14).frame(maxWidth: 720).frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                if let notice = store.openClawNotice(bot) {
                    Text(notice).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                composer()
            }
        }
    }
}
