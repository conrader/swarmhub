import SwiftUI

struct BotUsageOverview: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var note = ""
    @AppStorage("accent") private var accent = AppTheme.defaultAccent

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
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppColor.selection)
                        Capsule().fill(AppTheme.accentColor(for: accent))
                            .frame(width: geometry.size.width * CGFloat(percent) / 100)
                    }
                }
                .frame(height: 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context used").accessibilityValue("\(percent)%")
            }
            if let presence, !bot.isReadOnlyArchive, store.helperRosters[server.id] != .unavailable {
                let template = presence.session == nil ? store.herdrTemplate(for: bot) : presence.template
                if presence.session == nil || template != nil {
                    RuntimeAccountRow(server: server, template: template)
                        .id([bot.id.uuidString, server.id, server.address, server.sshHost, server.sshUser, template ?? ""])
                }
            }
            if let usage {
                ViewThatFits(in: .horizontal) {
                    HStack { cost(usage); Spacer(minLength: 6); total(usage) }
                    VStack(alignment: .leading, spacing: 3) { cost(usage); total(usage) }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if bot.documentReadOnly { Label("Read-only documents", systemImage: "doc.text.magnifyingglass").font(.caption) }
            if let cap = bot.sessionCapCents { Text(HerdrBotRequest.capLabel(cap)).font(.caption.monospacedDigit()) }
            if let budget = bot.goal?.spendProgress {
                Text(verbatim: budget).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if store.helperRosters[server.id] == .unavailable {
                Text(usage == nil ? "Workspace unavailable" : "Last reported before the workspace disconnected")
                    .font(.caption).foregroundStyle(.secondary)
            } else if usage == nil {
                Text(presence == nil ? "Waiting for session usage" :
                    presence?.session == nil ? "No active session" : "Usage has not been reported for this session")
                    .font(.caption).foregroundStyle(.secondary)
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

private struct RuntimeAccountRow: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let template: String?
    @State private var account: HerdrClient.RuntimeAccount?
    @State private var unavailable = false

    var body: some View {
        HStack(spacing: 6) {
            if let account {
                if let billing = account.billing { Text(billing); Spacer(minLength: 2) }
                switch account.state {
                case .signedIn: Text("CLI signed in")
                case .signedOut: Text("CLI signed out").foregroundStyle(AppColor.caution)
                case .unreported: Text("CLI account unreported")
                }
            } else if unavailable { Text("CLI status unavailable") }
        }
        .font(.caption).foregroundStyle(.secondary)
        .task {
            while !Task.isCancelled {
                do {
                    let next = try await store.herdrClient(for: server).runtimeAccount(template: template)
                    try Task.checkCancellation()
                    account = next
                    unavailable = false
                } catch HerdrClient.Failure.http(404, _) {
                    // Workspaces predating account status still supply session usage.
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    account = nil
                    unavailable = true
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
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
