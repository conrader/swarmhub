import SwiftUI

/// P38: the Activity tab's token usage for this agent (Settings → Usage keeps the per-profile table). Read when the tab
/// appears, after this agent's turn ends, or on Refresh; a result for an older context never replaces the current one.
/// The last reading (`AppStore.botUsageCache`) shows at once while a new one loads.
struct BotUsageView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var window = UsageWindow.week
    @State private var report: BotUsage?
    @State private var loadedAt: Date?
    @State private var loading = false
    @State private var refresh = 0

    private struct LoadContext: Equatable {
        var server: String, profile: String, sessions: Set<String>, sharedWith: [UUID], working: Bool, refresh: Int
    }

    private var context: LoadContext {
        LoadContext(server: bot.hermesBaseURL ?? store.defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL,
                    profile: bot.hermesProfile ?? "default", sessions: store.usageSessionIDs(for: bot),
                    sharedWith: store.usageProfiles.first { $0.bots.contains { $0.id == bot.id } }?.bots.map(\.id) ?? [],
                    working: store.isWorking(bot), refresh: refresh)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token usage").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small).accessibilityLabel("Loading token usage") }
                Picker("Period", selection: $window) { ForEach(UsageWindow.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(loading).help("Refresh token usage")
            }
            if let report {
                if let problem = report.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                } else {
                    let totals = report.totals(window)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(totals.totalTokens.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                        Text("tokens").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow { stat("Input", totals.inputTokens); stat("Output", totals.outputTokens) }
                        GridRow { stat("Cache read", totals.cacheReadTokens); stat("Sessions", totals.sessions) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
                    Text(report.scope == .profile ? "Everything on this agent's profile, routines and other channels included."
                         : "Shared profile: only this agent's chats, threads and group replies.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if totals.sessions == 0 { Text("No sessions in this period.").font(.caption2).foregroundStyle(.secondary) }
                    if report.truncated { Text("Partial totals: only the latest 2,000 sessions were read.").font(.caption2).foregroundStyle(.orange) }
                }
            } else if !loading {
                Text("Refresh to read token usage from this agent's server.").font(.caption).foregroundStyle(.secondary)
            }
            if let loadedAt, report?.problem == nil {
                Text("Updated \(loadedAt.formatted(date: .omitted, time: .shortened)) · a session counts in the period it started.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: context) {
            let requested = context
            // This agent's last reading stays up while the new one loads (never another agent's).
            let cached = store.botUsageCache[bot.id]
            report = cached?.report; loadedAt = cached?.at
            // Headless renders and samples never contact a server on appearance.
            guard store.botInfo.autoLoad || refresh > 0 || bot.isDemo || bot.isReadOnlyArchive else { return }
            loading = true
            let result = await store.loadUsage(for: bot)
            guard !Task.isCancelled, requested == context else { return }
            report = result; loadedAt = .now; loading = false
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.caption.weight(.medium)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
