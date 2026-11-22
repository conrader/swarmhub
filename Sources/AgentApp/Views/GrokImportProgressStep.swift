import SwiftUI

/// Importing: how far the whole import is (chats finished, one static bar), what the user should know now (a pause, a
/// stop, or that Grok stopped All history and the recent messages are imported instead), then one line per chat with
/// its state. The footer line counts every request (retries and file downloads included) and the running time.
struct GrokProgressStep: View {
    @ObservedObject var coordinator: GrokImportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                overall
                if let banner { banner }
            }.padding(.horizontal, 20).padding(.top, 16)
            ScrollView {
                VStack(spacing: 6) { ForEach(coordinator.progress) { row in progressRow(row) } }.padding(20)
            }
            Text("Requests so far: \(coordinator.requests) · Elapsed: \(coordinator.elapsedSeconds) s")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private var overall: some View {
        let total = coordinator.progress.count
        let finished = coordinator.progress.filter(\.status.isSettled).count
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(finished) of \(total) \(total == 1 ? "chat" : "chats")").font(.headline.monospacedDigit())
            ProgressView(value: Double(finished), total: Double(max(total, 1))).progressViewStyle(.linear)
                .accessibilityLabel("\(finished) of \(total) chats imported")
        }
    }

    private var banner: GrokNotice? {
        switch coordinator.step {
        case .paused(.network(let error)):
            return GrokNotice(text: "Grok's service could not be reached (\(error.description)). Retry remaining continues where it " +
                              "stopped; nothing is asked again and bots already imported stay.", symbol: "wifi.exclamationmark", tone: .caution)
        case .paused(.signInInvalid):
            return GrokNotice(text: "Grok stopped accepting the sign-in part-way. Continue reads Grok Bot's renewed sign-in, so macOS " +
                              "asks once more; bots already imported stay.", symbol: "person.crop.circle.badge.exclamationmark", tone: .caution)
        case .failed(let error):
            let more = error.recentStillAvailable ? " Recent messages from this Mac can still be imported." : ""
            var drift = "", said = ""
            if case .server(let refusal) = error {
                said = refusal.saidSentence
                drift = coordinator.versionDriftNote.map { " \($0)" } ?? ""
            }
            let stopped = (error.errorDescription ?? "The import stopped.") + said + " Nothing more was written; bots already " +
                "imported stay. Back lets you untick a bot and run again."
            return GrokNotice(text: stopped + drift + more, symbol: "exclamationmark.triangle", tone: .caution)
        default:
            guard let fallback = coordinator.fallback else { return nil }
            return GrokNotice(text: "Grok did not give the full history. \(fallback.userSummary) Importing the recent messages kept " +
                              "on this Mac instead.", symbol: "exclamationmark.triangle", tone: .caution)
        }
    }

    private func progressRow(_ row: GrokProgressRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol(row.status)).foregroundStyle(tint(row.status)).frame(width: 18)
                    .accessibilityHidden(true)
                Text(row.name).fontWeight(.medium).lineLimit(1)
                if row.isGroup { GrokTag(text: "group") }
                Spacer()
                Text(row.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if row.status == .fetching || row.status == .paused {
                ProgressView(value: row.fraction).progressViewStyle(.linear).controlSize(.small)
                    .accessibilityLabel("About \(Int(row.fraction * 100)) percent")
            }
        }
        .grokCard()
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ status: GrokProgressRow.Status) -> String {
        switch status {
        case .queued: "circle"
        case .readingCache, .fetching, .saving: "arrow.down.circle.fill"
        case .done: "checkmark.circle.fill"
        case .incomplete: "exclamationmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    private func tint(_ status: GrokProgressRow.Status) -> Color {
        switch status {
        case .queued, .skipped: .secondary
        case .readingCache, .fetching, .saving: .accentColor
        case .done: AppColor.good
        case .incomplete, .paused: AppColor.caution
        case .failed: .red
        }
    }
}

extension GrokProgressRow.Status {
    /// Nothing more will happen to this chat in this run.
    var isSettled: Bool {
        switch self {
        case .done, .incomplete, .skipped, .failed: true
        case .queued, .readingCache, .fetching, .saving, .paused: false
        }
    }
}
