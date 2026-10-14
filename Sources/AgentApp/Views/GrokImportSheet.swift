import AppKit
import SwiftUI

/// "Import from Grok Bot" (briefs/P10.md P10d 2): Found → Permission → Importing → Done, a plain step switch over
/// `GrokImportCoordinator`. 680×680 like the template import. Closing the sheet is Cancel: the run stops after the
/// in-flight request, every secret is forgotten, and finished bots stay. Progress is text and static bars only.
struct GrokImportSheet: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var coordinator: GrokImportCoordinator

    init(store: AppStore) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        _coordinator = StateObject(wrappedValue: GrokImportCoordinator(store: store, environment: .live(appVersion: version)))
    }

    /// Snapshots and tests: a coordinator with injected state.
    init(coordinator: GrokImportCoordinator) { _coordinator = StateObject(wrappedValue: coordinator) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }
                    .buttonStyle(.plain).accessibilityLabel("Close")
            }.padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            GrokImportFooter(coordinator: coordinator, close: close, useExportFolder: useExportFolder).padding(16)
        }
        .frame(width: 680, height: 680).background(AppColor.panel)
        .transaction { $0.animation = nil }
        .task { if coordinator.step == .idle { await coordinator.scan() } }
        .onDisappear { Task { await coordinator.dismiss() } }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.step {
        case .idle, .scanning:
            Text("Looking for Grok Bot on this Mac…").foregroundStyle(.secondary).padding(20)
        case .found:
            if case .unavailable(let reason) = coordinator.availability {
                GrokUnavailableView(reason: reason, rescan: { Task { await coordinator.scan() } }, useExportFolder: useExportFolder)
            } else {
                GrokFoundStep(coordinator: coordinator, useExportFolder: useExportFolder)
            }
        case .permission, .awaitingMacOS, .paused(.tokenExpired):
            GrokPermissionStep(coordinator: coordinator)
        case .failed(let error) where error.isSignInStep:
            GrokPermissionStep(coordinator: coordinator)
        case .running, .paused, .failed:
            GrokProgressStep(coordinator: coordinator)
        case .finished, .cancelled:
            GrokDoneStep(coordinator: coordinator)
        }
    }

    private var title: String {
        switch coordinator.step {
        case .permission, .awaitingMacOS: "One macOS prompt"
        case .running, .paused: "Importing from Grok Bot"
        case .finished: "Imported from Grok Bot"
        case .cancelled: "Import cancelled"
        default: "Import from Grok Bot"
        }
    }

    private var subtitle: String {
        switch coordinator.step {
        case .finished, .cancelled: "Bots imported so far stay in \(AppConstants.name). Importing again never duplicates a bot or a line."
        default: "Read-only: nothing is sent to Grok, and Grok Bot's own files are never changed."
        }
    }

    private func close() { store.showingGrokImport = false }

    /// "Use an export folder instead": the existing template-import sheet, unchanged.
    private func useExportFolder() {
        store.showingGrokImport = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            store.showingTemplateImport = true
        }
    }
}

extension GrokImportRunError {
    /// Failures about Grok Bot's sign-in or the Keychain: shown on the Permission step with one action each.
    var isSignInStep: Bool {
        switch self {
        case .keychain, .credentials, .signInUnreadable, .signedOut, .keychainItemMissing, .keychainReadInFlight: true
        default: false
        }
    }
}

/// Tier 2 said nothing can be imported: why, and the one thing to do about it.
struct GrokUnavailableView: View {
    let reason: GrokUnavailable
    let rescan: () -> Void
    let useExportFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(reason.message, systemImage: "exclamationmark.triangle").font(.callout)
            HStack {
                if reason.offersFolderAccess { Button("Choose Grok Bot's folder…") { chooseFolder() } }
                if reason == .cache(.notFound) || reason == .cache(.noRoster) {
                    Button("Open Grok Bot") { GrokImportActions.openGrokBot() }
                }
                if reason.offersExportFolder { Button("Use an export folder instead") { useExportFolder() } }
                Button("Check again") { rescan() }
            }
        }.padding(20)
    }

    /// Choosing the folder in the open panel gives this app access to it; then the sheet scans again.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = GrokLocation.live().dataFolder
        panel.prompt = "Allow"
        if panel.runModal() == .OK { rescan() }
    }
}

enum GrokImportActions {
    @MainActor static func openGrokBot() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokProtocol.bundleIdentifier)
            ?? URL(fileURLWithPath: GrokProtocol.appPath)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
