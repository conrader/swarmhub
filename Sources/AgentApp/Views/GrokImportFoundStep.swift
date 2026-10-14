import SwiftUI

/// Found (no prompt, no network): the checklist, the mode, the binding line and what the import promises.
struct GrokFoundStep: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var coordinator: GrokImportCoordinator
    let useExportFolder: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(headline).font(.headline)
                VStack(spacing: 6) { ForEach(coordinator.items) { item in row(item) } }
                Text("Bots created in Grok since Grok Bot last ran on this Mac are not listed.").font(.caption).foregroundStyle(.secondary)
                modePicker
                Toggle("Also refresh names, avatars and instructions from Grok", isOn: $coordinator.refreshIdentity)
                    .toggleStyle(.checkbox).font(.callout)
                Label(bindingLine, systemImage: coordinator.serverURL == nil ? "exclamationmark.circle" : "link")
                    .font(.callout).foregroundStyle(.secondary)
                if coordinator.mode == .full { GrokGuaranteeBox() }
                Button("Use an export folder instead") { useExportFolder() }.buttonStyle(.link).font(.callout)
            }.padding(20)
        }
    }

    private var headline: String {
        let bots = coordinator.items.filter { !$0.isGroup }.count, groups = coordinator.items.count - bots
        let version = coordinator.grokVersion.map { " \($0)" } ?? ""
        return "Grok Bot\(version) found: \(bots) \(bots == 1 ? "bot" : "bots")" +
            (groups > 0 ? " and \(groups) \(groups == 1 ? "group" : "groups")" : "")
    }

    private var bindingLine: String {
        guard let server = coordinator.serverURL else {
            return "No Hermes server is set: bots will be history-only until you add one."
        }
        return "Bots chat through \(URL(string: server)?.host ?? server)."
    }

    private func row(_ item: GrokFoundItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { coordinator.selected.contains(item.id) }, set: { _ in coordinator.toggle(item.id) }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(item.name)
            ShowcaseMark(mark: item.mark, seed: item.id, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    Text(item.isGroup ? "group" : (item.profile ?? "history only")).font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.08), in: Capsule())
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
                Button("Cancel") { close() }
            case .found:
                Button("Cancel") { close() }
                Button(primaryTitle) { Task { await coordinator.proceed() } }.buttonStyle(.borderedProminent)
                    .disabled(coordinator.selected.isEmpty || coordinator.availability?.canImport != true)
            case .permission:
                Button("Cancel") { close() }
                Button("Continue") { coordinator.continueToMacOS() }.buttonStyle(.borderedProminent).disabled(coordinator.keychainBusy)
            case .awaitingMacOS, .running:
                Button("Cancel") { coordinator.cancel() }
            case .paused(let pause):
                Button("Cancel") { coordinator.cancel() }
                Button(pause == .tokenExpired ? "Check again" : pause == .signInInvalid ? "Continue" : "Retry remaining") {
                    pause == .tokenExpired ? coordinator.checkAgain() : coordinator.retryRemaining()
                }.buttonStyle(.borderedProminent).disabled(coordinator.keychainBusy && pause == .signInInvalid)
            case .failed(let error):
                if error.recentStillAvailable { Button("Recent messages only") { coordinator.recentOnly() } }
                if error.isSignInStep {
                    Button("Try again") { coordinator.continueToMacOS() }.disabled(coordinator.keychainBusy)
                }
                Button("Close") { close() }.buttonStyle(.borderedProminent)
            case .cancelled:
                if coordinator.canImportWhatWasFetched { Button("Import what was fetched") { coordinator.importWhatWasFetched() } }
                Button("Done") { close() }.buttonStyle(.borderedProminent)
            case .finished:
                Button("Done") { close() }.buttonStyle(.borderedProminent)
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
