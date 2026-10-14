import SwiftUI

/// Done: "Get these bots talking" first (each bot's measured state and the actions that change it), then the details
/// (coverage, what was not imported, redactions, hidden prompts, failures) collapsed. Counts come from the store and
/// the archive files.
struct GrokDoneStep: View {
    @ObservedObject var coordinator: GrokImportCoordinator
    @State private var addingKeys = false
    @State private var showingDetails = false
    @State private var checking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Get these bots talking").font(.headline)
                VStack(spacing: 6) { ForEach(coordinator.botOutcomes) { outcome in botRow(outcome) } }
                if coordinator.botOutcomes.isEmpty { Text("No bot was imported.").foregroundStyle(.secondary) }
                actions
                if addingKeys {
                    Form {
                        BoxKeysPasteSection(title: "Add keys", prefill: coordinator.addKeysPrefill) { text in
                            await coordinator.addKeys(text)
                        }
                    }.formStyle(.grouped).frame(minHeight: 220)
                }
                Text("Imported chats are a read-only archive on this Mac; the bots start fresh and do not remember them.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Details", isExpanded: $showingDetails) { details }.font(.callout)
            }.padding(20)
        }
    }

    private var actions: some View {
        HStack {
            if !coordinator.needsKeyProfiles.isEmpty { Button("Add keys…") { addingKeys.toggle() } }
            Button(checking ? "Checking…" : "Check again") {
                checking = true
                Task { await coordinator.checkConnectionsAgain(); checking = false }
            }.disabled(checking)
            if coordinator.serverURL == nil { SettingsPaneButton(title: "Set up Hermes server…", pane: .servers).help("Opens \(SettingsLayout.path(.servers)).") }
        }
    }

    private func botRow(_ outcome: GrokImportOutcome) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.name).fontWeight(.medium)
                Text("\(outcome.profile ?? "no profile") · \(outcome.archiveLines) archived lines")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(outcome.connection.label).font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(colour(outcome.connection).opacity(0.15), in: Capsule()).foregroundStyle(colour(outcome.connection))
        }
        .padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private func colour(_ connection: GrokConnection) -> Color {
        switch connection {
        case .live: .green
        case .checking: .secondary
        case .needsKey, .historyOnly: .orange
        case .profileNotOnServer, .unreachable: .red
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
            if !coordinator.unfinishedIDs.isEmpty {
                Button("Retry remaining (\(coordinator.unfinishedIDs.count))") { Task { await coordinator.retryUnfinished() } }
                    .help("Imports the conversations above that did not finish; Full mode asks macOS once more first.")
            }
        }.padding(.top, 6)
    }
}
