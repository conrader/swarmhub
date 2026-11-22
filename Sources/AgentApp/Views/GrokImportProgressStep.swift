import SwiftUI

/// Importing: one row per selected conversation with its state and a static bar, a pause or stop banner, and a footer
/// line with the requests so far (every read, retries and file downloads included) and the elapsed time.
struct GrokProgressStep: View {
    @ObservedObject var coordinator: GrokImportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner { banner.padding(.horizontal, 20).padding(.top, 14) }
            ScrollView {
                VStack(spacing: 6) { ForEach(coordinator.progress) { row in progressRow(row) } }.padding(20)
            }
            Text("Requests so far: \(coordinator.requests) · Elapsed: \(coordinator.elapsedSeconds) s")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private var banner: AnyView? {
        switch coordinator.step {
        case .paused(.network(let error)):
            return AnyView(note("Grok's service could not be reached (\(error.description)). Retry remaining continues where it " +
                                "stopped; nothing is asked again and bots already imported stay.", symbol: "wifi.exclamationmark"))
        case .paused(.signInInvalid):
            return AnyView(note("Grok stopped accepting the sign-in part-way. Continue reads Grok Bot's renewed sign-in, so macOS " +
                                "asks once more; bots already imported stay.", symbol: "person.crop.circle.badge.exclamationmark"))
        case .failed(.server(let error)) where error.reason == .signInInvalid:
            let answer = error.statusDetail.map { " (\($0))" } ?? ""
            let drift = coordinator.versionDriftNote.map { " \($0)" } ?? ""
            let refusal = "Grok's service refused Grok Bot's sign-in on the first request\(answer).\(error.saidSentence) Asking " +
                "macOS again would send the same sign-in, so the import stopped; bots already imported stay."
            let text = refusal + drift + " Recent messages from this Mac can still be imported."
            return AnyView(note(text, symbol: "person.crop.circle.badge.exclamationmark"))
        case .failed(let error):
            let more = error.recentStillAvailable ? " Recent messages from this Mac can still be imported." : ""
            var drift = "", said = ""
            if case .server(let refusal) = error {
                said = refusal.saidSentence
                drift = coordinator.versionDriftNote.map { " \($0)" } ?? ""
            }
            let stopped = (error.errorDescription ?? "The import stopped.") + said + " Nothing more was written; bots already " +
                "imported stay. Back lets you untick a bot and run again."
            return AnyView(note(stopped + drift + more, symbol: "exclamationmark.triangle"))
        default:
            return nil
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private func progressRow(_ row: GrokProgressRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon(row.status)).foregroundStyle(.secondary).frame(width: 16)
                Text(row.name).fontWeight(.medium)
                if row.isGroup { Text("group").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(row.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let item = coordinator.items.first(where: { $0.id == row.id }) {
                Text(coordinator.destination(for: item)).font(.caption).foregroundStyle(.secondary)
            }
            if row.status == .fetching || row.status == .paused {
                ProgressView(value: row.fraction).progressViewStyle(.linear).controlSize(.small)
                    .accessibilityLabel("About \(Int(row.fraction * 100)) percent")
            }
        }
        .padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private func icon(_ status: GrokProgressRow.Status) -> String {
        switch status {
        case .queued: "circle"
        case .readingCache, .fetching, .saving: "arrow.down.circle"
        case .done: "checkmark.circle"
        case .incomplete, .paused: "pause.circle"
        case .skipped: "minus.circle"
        case .failed: "xmark.circle"
        }
    }
}
