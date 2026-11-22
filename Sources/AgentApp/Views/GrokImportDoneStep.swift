import SwiftUI

/// Done: the imported bots first, then the details (coverage, what was not imported, redactions, hidden prompts,
/// failures) collapsed. Counts come from the store and the archive files.
struct GrokDoneStep: View {
    @ObservedObject var coordinator: GrokImportCoordinator
    @State private var showingDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(coordinator.outcomeHeadline).font(.headline)
                if let fallback = coordinator.fallback {
                    GrokNotice(text: "Grok did not give the full history, so the recent messages kept on this Mac were imported. " +
                               fallback.userSummary, symbol: "exclamationmark.triangle", tone: .caution)
                }
                VStack(spacing: 6) { ForEach(coordinator.outcomes) { outcome in botRow(outcome) } }
                Text("Bots keep their name, avatar and instructions and run on your Herdr server. Each bot reads its imported " +
                     "conversation before its first reply; long conversations are summarised first. Group chats stay a read-only archive on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Details", isExpanded: $showingDetails) { details }.font(.callout)
            }.padding(20)
        }
    }

    private func botRow(_ outcome: GrokImportOutcome) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(outcome.row.status)).foregroundStyle(tint(outcome.row.status)).frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(outcome.name).fontWeight(.medium)
                    if outcome.isGroup { GrokTag(text: "group") }
                }
                Text(outcome.statusLabel + (outcome.row.reason.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                if let target = coordinator.savedDestination(for: outcome) {
                    Text(target.location).font(.caption).foregroundStyle(.secondary)
                    if let path = target.workspace { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if outcome.botID != nil {
                Text("\(outcome.archiveLines) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Open") { coordinator.open(outcome) }
            }
        }
        .grokCard()
    }

    private func symbol(_ status: GrokImportRunRow.Status) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .incomplete: "exclamationmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func tint(_ status: GrokImportRunRow.Status) -> Color {
        switch status {
        case .done: AppColor.good
        case .incomplete: AppColor.caution
        case .skipped: .secondary
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(coordinator.outcomes) { outcome in
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.name + (outcome.isGroup ? " (group)" : "")).fontWeight(.medium)
                    Text(outcome.coverageText).font(.caption).foregroundStyle(.secondary)
                    if let dropped = outcome.droppedText { Text("Not imported: \(dropped)").font(.caption).foregroundStyle(.secondary) }
                    if outcome.row.redactions > 0 {
                        Text("Secret-like text replaced: \(outcome.row.redactions)").font(.caption).foregroundStyle(.secondary)
                    }
                    if outcome.row.hiddenMessages > 0 {
                        Text("Hidden prompts kept and marked: \(outcome.row.hiddenMessages)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = outcome.row.reason { Text("Failed: \(reason)").font(.caption).foregroundStyle(.red) }
                }
            }
            let failed = coordinator.progress.filter { if case .failed = $0.status { true } else { false } }
            ForEach(failed) { row in Text("\(row.name): \(row.label)").font(.caption).foregroundStyle(.red) }

        }.padding(.top, 6)
    }
}
