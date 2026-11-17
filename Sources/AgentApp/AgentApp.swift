import AppKit
import Darwin
import SwiftUI

@main struct AgentAppMain: App {
    @StateObject private var store: AppStore
    @StateObject private var updater: AppUpdater
    @NSApplicationDelegateAdaptor(AppIconAppearance.self) private var iconAppearance
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
    private let snapshotAppearance: String?
    init() {
        if let code = HeadlessCommands.runIfRequested() { exit(code) }
        AppIconAppearance.applyAtLaunch()
        SidebarWidth.dropStaleSavedWidths()
        snapshotAppearance = ProcessInfo.processInfo.environment["AGENTAPP_APPEARANCE"]
        let appStore = SetupPreview.isRequested() ? SetupPreview.makeStore()
            : AppStore(demoMode: ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] != nil)
        _store = StateObject(wrappedValue: appStore)
        if let path = UISmoke.reportPath() { UISmoke.start(store: appStore, path: path) }
        PerformanceMetrics.reportReady()
        if ProcessInfo.processInfo.environment["AGENTAPP_BENCHMARK"] == "1" { exit(0) }
        if let path = ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] { SnapshotRenderer.capture(store: appStore, to: path); exit(0) }
        _updater = StateObject(wrappedValue: AppUpdater())
        SoftwareUpdateModel.shared.startDailyChecks(store: appStore)
    }
    var body: some Scene {
        normalScenes
    }
    @SceneBuilder private var normalScenes: some Scene {
        WindowGroup(AppConstants.name, id: ContentView.windowID) {
            ContentView()
                .environmentObject(store)
                .defaultAppStorage(store.defaults)
                .preferredColorScheme(AppTheme.colorScheme(for: snapshotAppearance ?? appearance))
                .frame(minWidth: 980, minHeight: 620)
        }
            .defaultSize(width: 1120, height: 760)
            .windowStyle(.hiddenTitleBar)
            .commands { AppCommands(store: store, updater: updater) }
        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
        }.windowResizability(.contentSize)
        Window(SetupCopy.windowTitle, id: SetupView.windowID) {
            SetupView()
                .environmentObject(store)
                .defaultAppStorage(store.defaults)
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
                .tint(AppTheme.accentColor(for: accent))
        }.windowResizability(.contentSize)
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updater)
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
        }
    }
}
