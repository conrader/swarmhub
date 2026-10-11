import AppKit
import Darwin
import SwiftUI

@main struct AgentAppMain: App {
    @StateObject private var store: AppStore
    init() {
        if let appearance = ProcessInfo.processInfo.environment["AGENTAPP_APPEARANCE"] { UserDefaults.standard.set(appearance, forKey: "appearance") }
        let appStore = AppStore()
        if ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] != nil { appStore.loadDemoData() }
        _store = StateObject(wrappedValue: appStore)
        PerformanceMetrics.reportReady()
        if ProcessInfo.processInfo.environment["AGENTAPP_BENCHMARK"] == "1" { exit(0) }
        if let path = ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] { SnapshotRenderer.capture(store: appStore, to: path); exit(0) }
    }
    var body: some Scene {
        WindowGroup(AppConstants.name) {
            ContentView().environmentObject(store).frame(minWidth: 1040, minHeight: 680)
        }
            .defaultSize(width: 1360, height: 850)
            .commands {
                CommandGroup(after: .newItem) { Button("New Agent") { NotificationCenter.default.post(name: .newBot, object: nil) }.keyboardShortcut("n") }
                CommandMenu("Navigate") {
                    Button("Command Palette…") { NotificationCenter.default.post(name: .showPalette, object: nil) }.keyboardShortcut("k")
                    Button("Toggle Agent Info") { NotificationCenter.default.post(name: .toggleInfo, object: nil) }.keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
        Settings { SettingsView() }
    }
}
