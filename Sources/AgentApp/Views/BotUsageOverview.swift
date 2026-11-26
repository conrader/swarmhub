import SwiftUI

struct BotUsageOverview: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var note = ""

    var body: some View {
        let server = store.herdrServer(for: bot)
        let presence = store.herdrPresence(for: bot)
        let usage = presence?.usage
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Context & spend").accessibilityAddTraits(.isHeader)
                Spacer()
                if let percent = usage?.contextPercent { Text("\(percent)% ctx").monospacedDigit() }
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let percent = usage?.contextPercent {
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear).accessibilityLabel("Context used").accessibilityValue("\(percent)%")
            }
            if let usage {
                ViewThatFits(in: .horizontal) {
                    HStack { cost(usage); Spacer(minLength: 6); total(usage) }
                    VStack(alignment: .leading, spacing: 3) { cost(usage); total(usage) }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if store.helperRosters[server.id] == .unavailable {
                Text(usage == nil ? "Workspace unavailable" : "Last reported before the workspace disconnected")
                    .font(.caption).foregroundStyle(.secondary)
            } else if usage == nil {
                Text(presence == nil ? "Waiting for session usage" :
                    presence?.session == nil ? "No active session" : "Usage has not been reported for this session")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let goal = bot.goal, goal.state.active, let spend = goal.spendProgress {
                Text(spend).font(.caption.monospacedDigit())
            }
            SummarizeBotButton(bot: bot) { note = $0 }
            if !note.isEmpty { Text(note).font(.caption).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.sessionUsage")
    }

    private func cost(_ usage: HerdrClient.SessionUsage) -> Text {
        if let amount = usage.estimatedCost { return Text("Est. \(amount)") }
        return Text("No priced usage reported")
    }

    private func total(_ usage: HerdrClient.SessionUsage) -> Text {
        Text("\(usage.totalTokens.formatted()) tokens total")
    }
}

struct SummarizeBotButton: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var disabled = false
    let notice: (String) -> Void

    var body: some View {
        if bot.messages.contains(where: { $0.role == .assistant && !$0.isStreaming && $0.presentation == .text }) {
            Button(store.summarizingChats.contains(bot.id) ? "Preparing chat summary…" : "Summarize & start fresh") {
                notice("")
                Task {
                    do {
                        try await store.summarizeAndStartFresh(bot)
                        notice("Summary ready. Your next message continues in a fresh session.")
                        await store.refreshHerdrAgentReading(for: bot)
                    } catch { notice(error.localizedDescription) }
                }
            }
            .disabled(disabled || store.herdrBotIsBusy(bot) || store.summarizingChats.contains(bot.id))
            .help("Keep your messages and give the new session a summary of this chat.")
        }
    }
}
