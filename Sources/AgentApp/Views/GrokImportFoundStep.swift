import SwiftUI

/// Found (no prompt, no network): the checklist, the mode, the binding line and what the import promises.
struct GrokFoundStep: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var coordinator: GrokImportCoordinator
    let useExportFolder: () -> Void
    @State private var editingDescription: GrokFoundItem?
    @State private var descriptionDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(headline).font(.headline)
                if coordinator.exportBundles == nil { modePicker }
                Toggle("Refresh existing names, avatars, descriptions and instructions", isOn: $coordinator.refreshIdentity)
                    .toggleStyle(.checkbox).font(.callout)
                if coordinator.mode == .full { GrokGuaranteeBox() }
                if let plan = coordinator.destinationPlan, plan.offer.programs.count > 1 {
                    Picker("Program for new bots", selection: Binding(
                        get: { coordinator.destinationPlan?.template ?? plan.offer.programs[0].template },
                        set: { coordinator.destinationPlan?.template = $0 })) {
                            ForEach(plan.offer.programs) { Text(plan.offer.label($0)).tag($0.template) }
                        }
                }
                HStack {
                    Button("Select all") { coordinator.selected = Set(coordinator.items.map(\.id)) }
                    Button("Clear") { coordinator.selected.removeAll() }
                    Text("Selecting a group also selects its members.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) { ForEach(coordinator.items) { item in row(item) } }
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
        return "Grok Bot\(version) found: \(bots) \(bots == 1 ? "bot" : "bots")" +
            (groups > 0 ? " and \(groups) \(groups == 1 ? "group" : "groups")" : "")
    }

    private func row(_ item: GrokFoundItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { coordinator.selected.contains(item.id) }, set: { _ in coordinator.toggle(item.id) }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(item.name)
            ShowcaseMark(mark: item.mark, seed: item.id, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    Text(item.isGroup ? "group" : "bot").font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.08), in: Capsule())
                }
                Text(coordinator.destination(for: item)).font(.caption).foregroundStyle(.secondary)
                if !item.isGroup {
                    let existing = store.bots.first { $0.grokSourceID == item.id }
                    let edited = coordinator.destinationPlan?.descriptions[item.id]
                    let description = edited ?? (coordinator.refreshIdentity ? nil : existing?.botDescription) ?? item.description
                    if !description.isEmpty { Text(description).font(.caption).lineLimit(4) }
                    if item.needsDescriptionEdit, edited == nil, PreparedGrokBundle.meaningful(existing?.botDescription).isEmpty {
                        Label("No specific description in Grok", systemImage: "exclamationmark.circle").font(.caption)
                        Button("Edit description") { descriptionDraft = item.description; editingDescription = item }.buttonStyle(.link).font(.caption)
                    }
                    if let plan = coordinator.destinationPlan {
                        if let id = existing?.id ?? plan.newBotIDs[item.id] {
                            let root = existing == nil ? plan.offer.workspaceRoot : nil
                            Text(root.map { $0 + "/" + id.uuidString.lowercased() } ?? "Bot workspace · " + id.uuidString.lowercased())
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if existing == nil, plan.offer.programs.count > 1 {
                            Picker("Program for \(item.name)", selection: Binding(
                                get: { coordinator.destinationPlan?.templates[item.id] ?? "" },
                                set: { coordinator.destinationPlan?.templates[item.id] = $0.isEmpty ? nil : $0 })) {
                                    Text("Use import default").tag("")
                                    ForEach(plan.offer.programs) { Text(plan.offer.label($0)).tag($0.template) }
                                }.font(.caption)
                        }
                    }
                }
                Text(details(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private func details(_ item: GrokFoundItem) -> String {
        var parts = ["\(item.cachedMessages) cached \(item.cachedMessages == 1 ? "message" : "messages")"]
        if let date = item.importedAt {
            let day = date.formatted(date: .abbreviated, time: .omitted)
            parts.append("already in \(AppConstants.name) \(day), \(item.importedLines) lines")
        } else if item.importedLines > 0 {
            parts.append("already in \(AppConstants.name), \(item.importedLines) lines")
        }
        if item.hiddenInGrok { parts.append("hidden in Grok") }
        return parts.joined(separator: " · ")
    }

    private var modePicker: some View {
        let estimate = coordinator.requestEstimate
        let fullAvailable = coordinator.availability == .ready
        return VStack(alignment: .leading, spacing: 8) {
            Picker("History", selection: $coordinator.mode) {
                Text("All history Grok returns").tag(GrokImportMode.full).disabled(!fullAvailable)
                Text("Recent messages from this Mac").tag(GrokImportMode.recent)
            }.pickerStyle(.radioGroup).font(.callout)
            Group {
                if coordinator.mode == .full {
                    Text("One macOS prompt; at least \(estimate.requests) read requests, about \(estimate.seconds) s.")
                } else {
                    Text("The latest 28–200 entries of each chat, from Grok Bot's cache on this Mac: no prompt, no network.")
                }
            }.font(.caption).foregroundStyle(.secondary)
            if case .cacheOnly(let reason) = coordinator.availability {
                Label("All history is not available: \(reason.errorDescription ?? "")", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// What the Full import promises, and no more (Rule 6: honest copy).
struct GrokGuaranteeBox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this import does").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Self.lines, id: \.self) { line in
                Label(line, systemImage: "checkmark").font(.caption).labelStyle(.titleAndIcon)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    static let lines = [
        "Read-only: it lists your own history and downloads entries Grok stores as files, from api2.cursor.sh; it sends nothing else.",
        "Grok Bot's sign-in is kept in memory only while importing, and up to ten minutes if paused; never saved, shown or logged.",
        "It never refreshes or changes the sign-in, and never writes to Grok Bot's files.",
        "History is saved in \(AppConstants.name)'s data folder on this Mac, with secret-like text replaced by [REDACTED].",
        "It uses Grok Bot's own private interface, and can stop working when Grok changes it.",
    ]
}

/// The buttons for each step.
struct GrokImportFooter: View {
    @ObservedObject var coordinator: GrokImportCoordinator
    let close: () -> Void
    let useExportFolder: () -> Void

    var body: some View {
        HStack {
            if showsBack { Button("Back") { coordinator.back() } }
            Spacer()
            switch coordinator.step {
            case .idle, .scanning:
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            case .found:
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle) { Task { await coordinator.proceed() } }.buttonStyle(.appleProminent)
                    .keyboardShortcut(.defaultAction).disabled(!coordinator.canProceed)
            case .permission:
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Continue") { coordinator.continueToMacOS() }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction).disabled(coordinator.keychainBusy)
            case .awaitingMacOS, .running:
                Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
            case .paused(let pause):
                Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
                Button(pause == .tokenExpired ? "Check again" : pause == .signInInvalid ? "Continue" : "Retry remaining") {
                    pause == .tokenExpired ? coordinator.checkAgain() : coordinator.retryRemaining()
                }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction).disabled(coordinator.keychainBusy && pause == .signInInvalid)
            case .failed(let error):
                if error.recentStillAvailable { Button("Recent messages only") { coordinator.recentOnly() } }
                if error.isSignInStep {
                    Button("Try again") { coordinator.continueToMacOS() }.disabled(coordinator.keychainBusy)
                }
                Button("Close") { close() }.buttonStyle(.appleProminent).keyboardShortcut(.cancelAction)
            case .cancelled:
                if coordinator.canImportWhatWasFetched { Button("Import what was fetched") { coordinator.importWhatWasFetched() } }
                Button("Done") { close() }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
            case .finished:
                if !coordinator.unfinishedIDs.isEmpty {
                    Button("Retry remaining (\(coordinator.unfinishedIDs.count))") { Task { await coordinator.retryUnfinished() } }
                }
                Button("Done") { close() }.buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var showsBack: Bool {
        switch coordinator.step {
        case .permission: true
        case .failed(let error): !error.isSignInStep
        default: false
        }
    }

    private var primaryTitle: String {
        let count = coordinator.selected.count
        return coordinator.mode == .full ? "Continue" : "Import \(count) \(count == 1 ? "chat" : "chats")"
    }
}
