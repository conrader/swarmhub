import SwiftUI

/// Settings → Usage: sessions, messages and tokens per bot (profile) and in total, read on demand from
/// each profile's `GET /api/sessions`. A plain table plus a static bar list; nothing animates.
struct SettingsUsagePane: View {
    @EnvironmentObject private var store: AppStore
    @State private var window = UsageWindow.week
    @State private var rows: [ProfileUsage] = []
    @State private var loading = false; @State private var loadedAt: Date?

    var body: some View {
        Section {
            HStack {
                Picker("Period", selection: $window) { ForEach(UsageWindow.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button(loadedAt == nil ? "Load" : "Refresh") { load() }.disabled(loading)
            }
            if let loadedAt { Text("Read from Hermes sessions \(loadedAt.formatted(date: .omitted, time: .shortened)); a session counts in the period it started.").font(.caption).foregroundStyle(.secondary) }
        }
        if !rows.isEmpty {
            let total = ProfileUsage.total(rows, window: window)
            Section("Total") {
                HStack(spacing: 18) { stat("Sessions", total.sessions); stat("Messages", total.messages); stat("Input", total.inputTokens); stat("Output", total.outputTokens); stat("Cache read", total.cacheReadTokens) }
            }
            Section("Per bot") {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { Text("Bot").gridColumnAlignment(.leading); Text("Sessions"); Text("Messages"); Text("Input"); Text("Output") }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        let totals = row.totals(window)
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) { Text(row.label).lineLimit(1); Text(row.problem ?? row.profile + (row.truncated ? " · first 2,000 sessions" : "")).font(.caption2).foregroundStyle(row.problem == nil ? Color.secondary : Color.orange).lineLimit(2) }
                            Text("\(totals.sessions)").monospacedDigit(); Text("\(totals.messages)").monospacedDigit()
                            Text(ProfileUsage.compact(totals.inputTokens)).monospacedDigit(); Text(ProfileUsage.compact(totals.outputTokens)).monospacedDigit()
                        }
                    }
                }
            }
            Section("Tokens (input + output)") {
                let peak = max(1, rows.map { $0.totals(window).totalTokens }.max() ?? 1)
                ForEach(rows.sorted { $0.totals(window).totalTokens > $1.totals(window).totalTokens }) { row in
                    let value = row.totals(window).totalTokens
                    HStack(spacing: 8) {
                        Text(row.label).lineLimit(1).frame(width: 130, alignment: .leading)
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 3).fill(.tint).opacity(0.75).frame(width: max(value > 0 ? 2 : 0, proxy.size.width * CGFloat(value) / CGFloat(peak)))
                        }.frame(height: 10)
                        Text(ProfileUsage.compact(value)).monospacedDigit().font(.caption).frame(width: 56, alignment: .trailing)
                    }
                }
            }.transaction { $0.animation = nil }
        } else if !loading {
            Text(store.usageProfiles.isEmpty ? "No bot is bound to a Hermes profile." : "Press Load to read session usage from \(store.usageProfiles.count) profile(s).").foregroundStyle(.secondary)
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(ProfileUsage.compact(value)).font(.title3.weight(.semibold)).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
    }

    private func load() {
        loading = true
        Task { rows = await store.loadUsage(); loadedAt = .now; loading = false }
    }
}

/// Settings → Updates: this build's version and commit, and an on-demand check of the latest GitHub release.
struct SettingsUpdatesPane: View {
    @State private var status: UpdateStatus?; @State private var checking = false
    private let info = AppBuildInfo.current()

    var body: some View {
        Section {
            LabeledContent("Version", value: info.version + (info.build.map { " (\($0))" } ?? ""))
            LabeledContent("Build", value: info.shortSHA.map { $0 + (info.dirty ? " (uncommitted changes)" : "") } ?? "not packaged")
        }
        Section {
            HStack { Button("Check for Updates") { check() }.disabled(checking); if checking { ProgressView().controlSize(.small) } }
            if let status {
                Text(status.message).foregroundStyle(.secondary)
                if case .newer(let release) = status, let page = release.pageURL { Link("Open \(release.name ?? release.tag) on GitHub", destination: page) }
            }
            Text("Checks github.com/\(AppConstants.releasesRepo) releases only when you press the button. Nothing is downloaded or installed.").font(.caption).foregroundStyle(.secondary)
        }
        AcknowledgementsSection()
    }

    private func check() {
        checking = true
        Task { status = await ReleaseChecker.check(current: info.version); checking = false }
    }
}
