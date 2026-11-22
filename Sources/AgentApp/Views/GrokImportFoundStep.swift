import SwiftUI

/// Found (no prompt, no network): the one question first (how much history, as two large cards), then the options,
/// then the chats to import. What the full import promises is one click away, not in the way.
struct GrokFoundStep: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var coordinator: GrokImportCoordinator
    let useExportFolder: () -> Void
    @State private var editingDescription: GrokFoundItem?
    @State private var descriptionDraft = ""
    @State private var showingPromises = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if coordinator.exportBundles == nil { historyChoice }
                options
                chats
                Button("Use an export folder instead") { useExportFolder() }.buttonStyle(.link).font(.callout)
            }.padding(20)
        }
        .sheet(item: $editingDescription) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("Description for \(item.name)").font(.headline)
                TextField("What does this bot do?", text: $descriptionDraft, axis: .vertical).lineLimit(3...6)
                HStack {
                    Button("Cancel") { editingDescription = nil }.keyboardShortcut(.cancelAction)
                    Button("Use description") {
                        coordinator.destinationPlan?.descriptions[item.id] = descriptionDraft
                        editingDescription = nil
                    }.keyboardShortcut(.defaultAction).disabled(descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(minWidth: 380)
        }
    }

    private var headline: String {
        let bots = coordinator.items.filter { !$0.isGroup }.count, groups = coordinator.items.count - bots
        let version = coordinator.grokVersion.map { " \($0)" } ?? ""
        return "\(bots) \(bots == 1 ? "bot" : "bots")" + (groups > 0 ? " and \(groups) \(groups == 1 ? "group" : "groups")" : "") +
            " in Grok Bot\(version)"
    }

    private func row(_ item: GrokFoundItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { coordinator.selected.contains(item.id) }, set: { _ in coordinator.toggle(item.id) }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(item.name)
            ShowcaseMark(mark: item.mark, seed: item.id, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    if item.isGroup { GrokTag(text: "group") }
                    if item.hiddenInGrok { GrokTag(text: "hidden in Grok") }
                }
                Text(coordinator.destination(for: item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(workspace(for: item) ?? "")
                if !item.isGroup { botDetails(item) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(item.cachedMessages) cached").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if item.importedLines > 0 {
                    Text("\(item.importedLines) already here").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help(item.importedAt.map { "Imported \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
                }
            }
        }
        .grokCard()
    }

    /// The description (two lines at most), the nudge to write one when Grok had none, and the per-bot program.
    @ViewBuilder private func botDetails(_ item: GrokFoundItem) -> some View {
        let existing = store.bots.first { $0.grokSourceID == item.id }
        let edited = coordinator.destinationPlan?.descriptions[item.id]
        let description = edited ?? (coordinator.refreshIdentity ? nil : existing?.botDescription) ?? item.description
        if !description.isEmpty { Text(description).font(.caption).lineLimit(2) }
        if item.needsDescriptionEdit, edited == nil, PreparedGrokBundle.meaningful(existing?.botDescription).isEmpty {
            HStack(spacing: 6) {
                Label("No description in Grok", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                Button("Edit description") { descriptionDraft = item.description; editingDescription = item }.buttonStyle(.link).font(.caption)
            }
        }
        if let plan = coordinator.destinationPlan, existing == nil, plan.offer.programs.count > 1 {
            Picker("Program for \(item.name)", selection: Binding(
                get: { coordinator.destinationPlan?.templates[item.id] ?? "" },
                set: { coordinator.destinationPlan?.templates[item.id] = $0.isEmpty ? nil : $0 })) {
                    Text("Use import default").tag("")
                    ForEach(plan.offer.programs) { Text(plan.offer.label($0)).tag($0.template) }
                }.font(.caption)
        }
    }

    /// Where the bot's workspace is (a tooltip: a long path is a detail, not a line of every row).
    private func workspace(for item: GrokFoundItem) -> String? {
        guard !item.isGroup, let plan = coordinator.destinationPlan else { return nil }
        let existing = store.bots.first { $0.grokSourceID == item.id }
        guard let id = existing?.id ?? plan.newBotIDs[item.id] else { return nil }
        let root = existing == nil ? plan.offer.workspaceRoot : nil
        return root.map { $0 + "/" + id.uuidString.lowercased() } ?? "Bot workspace · " + id.uuidString.lowercased()
    }

    // MARK: The question, the options, the list

    private var historyChoice: some View {
        let estimate = coordinator.requestEstimate
        let fullAvailable = coordinator.availability == .ready
        return VStack(alignment: .leading, spacing: 10) {
            Text("How much history?").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                GrokChoiceCard(title: "All history", detail: "Everything Grok still returns for each chat.",
                               footnote: fullAvailable ? "One macOS prompt · about \(estimate.seconds) s" : "Not available now",
                               selected: coordinator.mode == .full, enabled: fullAvailable) { coordinator.mode = .full }
                GrokChoiceCard(title: "Recent messages", detail: "The latest 28–200 entries of each chat, kept on this Mac.",
                               footnote: "No prompt · no network", selected: coordinator.mode == .recent) { coordinator.mode = .recent }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let note = historyNote { GrokNotice(text: note.text, symbol: note.symbol, tone: note.caution ? .caution : .info) }
            if coordinator.mode == .full {
                DisclosureGroup("What All history reads and keeps", isExpanded: $showingPromises) {
                    GrokGuaranteeBox().padding(.top, 6)
                }.font(.callout)
            }
        }
    }

    /// At most one sentence under the cards: why All history is off, that Grok stopped it last time, or that Grok Bot
    /// is newer than the version this import was checked against.
    private var historyNote: (text: String, symbol: String, caution: Bool)? {
        if case .cacheOnly(let reason) = coordinator.availability {
            return ("All history is not available: \(reason.errorDescription ?? "")", "info.circle", false)
        }
        if let refusal = coordinator.refusalNote { return (refusal, "exclamationmark.triangle", true) }
        if coordinator.mode == .full, let drift = coordinator.versionDriftNote {
            return ("\(drift) If Grok stops All history, the recent messages are imported instead.", "info.circle", false)
        }
        return nil
    }

    @ViewBuilder private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Refresh existing names, avatars, descriptions and instructions", isOn: $coordinator.refreshIdentity)
                .toggleStyle(.checkbox).font(.callout)
            if let plan = coordinator.destinationPlan, plan.offer.programs.count > 1 {
                Picker("Program for new bots", selection: Binding(
                    get: { coordinator.destinationPlan?.template ?? plan.offer.programs[0].template },
                    set: { coordinator.destinationPlan?.template = $0 })) {
                        ForEach(plan.offer.programs) { Text(plan.offer.label($0)).tag($0.template) }
                    }
                HerdrProgramNote(note: plan.offer.program(coordinator.destinationPlan?.template ?? plan.offer.programs[0].template)?.note)
            }
        }
    }

    private var chats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(headline).font(.headline)
                Spacer()
                Text("\(coordinator.selected.count) of \(coordinator.items.count) selected")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Select all") { coordinator.selected = Set(coordinator.items.map(\.id)) }.buttonStyle(.link).font(.callout)
                Button("Clear") { coordinator.selected.removeAll() }.buttonStyle(.link).font(.callout)
            }
            if coordinator.items.contains(where: \.isGroup) {
                Text("Selecting a group also selects its members.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) { ForEach(coordinator.items) { item in row(item) } }
        }
    }
}

/// What the Full import promises, and no more (Rule 6: honest copy).
struct GrokGuaranteeBox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.lines, id: \.self) { line in
                Label(line, systemImage: "checkmark").font(.caption).labelStyle(.titleAndIcon)
            }
        }
        .grokCard(padding: 12)
    }

    static let lines = [
        "Read-only: it lists your own history and downloads entries Grok stores as files, from api2.cursor.sh; it sends nothing else.",
        "Grok Bot's sign-in is kept in memory only while importing, and up to ten minutes if paused; never saved, shown or logged.",
        "It never refreshes or changes the sign-in, and never writes to Grok Bot's files.",
        "History is saved in \(AppConstants.name)'s data folder on this Mac, with secret-like text replaced by [REDACTED].",
        "It uses Grok Bot's own private interface, and can stop working when Grok changes it.",
    ]
}
