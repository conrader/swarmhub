import AppKit
import SwiftUI

/// "Import from Grok Bot": Found → Permission → Importing → Done, a plain step switch over
/// `GrokImportCoordinator`. 680×680 like the template import. Closing the sheet is Cancel: the run stops after the
/// in-flight request, every secret is forgotten, and finished bots stay. Progress is text and static bars only.
struct GrokImportSheet: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var coordinator: GrokImportCoordinator
    @State private var historyFolderUnavailable = false
    @State private var exportError: String?
    @AccessibilityFocusState private var headingFocused: Bool
    private var startsWithExport = false

    init(store: AppStore) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        _coordinator = StateObject(wrappedValue: GrokImportCoordinator(store: store, environment: .live(appVersion: version), destination: store.grokDestination, requiresTestedHost: true))
        startsWithExport = store.grokStartsWithExport
    }

    /// Snapshots and tests: a coordinator with injected state.
    init(coordinator: GrokImportCoordinator) { _coordinator = StateObject(wrappedValue: coordinator) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }
                    .buttonStyle(.plain).accessibilityLabel("Close")
            }.padding(20)
            Divider()
            if coordinator.testedServer != nil {
                destination.padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            GrokImportFooter(coordinator: coordinator, close: close, useExportFolder: useExportFolder).padding(16)
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 540, idealHeight: 680).background(AppColor.panel)
        .transaction { $0.animation = nil }
        .task {
            if coordinator.step == .idle {
                if startsWithExport { useExportFolder() }
                if coordinator.step == .idle { await coordinator.scan() }
            }
        }
        .onChange(of: coordinator.step) { _, _ in headingFocused = true }
        .alert("Couldn’t open the Grok export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .onDisappear { Task { await coordinator.dismiss() } }
        .alert("Couldn’t open the history folder", isPresented: $historyFolderUnavailable) {
            Button("OK", role: .cancel) {}
        }
    }

    /// One line about where things land, and the folder a click away (its path is the button's tooltip).
    private var destination: some View {
        let folder = coordinator.historyDirectory
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let server = coordinator.testedServer {
                    Text("Destination · \(server.name)" + (server.place == server.name ? "" : " · \(server.place)"))
                        .font(.callout.weight(.semibold))
                }
                Text("History stays on this Mac; bots start with a fresh conversation.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") {
                do {
                    try GrokHistoryStore.prepareDirectory(folder)
                    ExternalLink.revealInFinder(folder)
                } catch {
                    historyFolderUnavailable = true
                }
            }.help((folder.path as NSString).abbreviatingWithTildeInPath)
        }
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
        case .running: "Importing from Grok Bot"
        case .paused: "Import paused"
        case .failed(let error) where !error.isSignInStep: "Import stopped"
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

    /// An export uses the same host, preview, identity policy and receipt as a cache import.
    private func useExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.directoryURL = AppConstants.grokExportFolder()
        panel.prompt = "Review export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { coordinator.useExportBundles(try GrokBundleLoader.load(from: url)) }
        catch { exportError = (error as? GrokBundleError)?.localizedDescription ?? "Choose a Grok Bot export folder or bundle JSON." }
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
                Button("Use an export folder instead") { useExportFolder() }
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
        ExternalLink.openApplication(at: url)
    }
}
