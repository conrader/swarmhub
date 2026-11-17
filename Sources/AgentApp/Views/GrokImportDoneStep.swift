import SwiftUI

/// Done: the imported bots first, then the details (coverage, what was not imported, redactions, hidden prompts,
/// failures) collapsed. Counts come from the store and the archive files.
struct GrokDoneStep: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var coordinator: GrokImportCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var showingDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Imported bots").font(.headline)
                VStack(spacing: 6) { ForEach(coordinator.botOutcomes) { outcome in botRow(outcome) } }
                if coordinator.botOutcomes.isEmpty { Text("No bot was imported.").foregroundStyle(.secondary) }
                if !store.herdrConfigured && !coordinator.botOutcomes.isEmpty {
                    Button("Connect an agent to use my bot") {
                        store.showingGrokImport = false
                        store.openSetup(openWindow: openWindow)
                    }
                }
                Text("Each bot keeps its name, avatar and instructions and runs as an agent on your Herdr server. Imported chats are a read-only archive on this Mac; the bots start fresh and do not remember them.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Details", isExpanded: $showingDetails) { details }.font(.callout)
            }.padding(20)
        }
    }

    private func botRow(_ outcome: GrokImportOutcome) -> some View {
        HStack(spacing: 10) {
            Text(outcome.name).fontWeight(.medium)
            Spacer()
            Text("\(outcome.archiveLines) archived lines").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
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
            if !coordinator.unfinishedIDs.isEmpty {
                Button("Retry remaining (\(coordinator.unfinishedIDs.count))") { Task { await coordinator.retryUnfinished() } }
                    .help("Imports the conversations above that did not finish; Full mode asks macOS once more first.")
            }
        }.padding(.top, 6)
    }
}
