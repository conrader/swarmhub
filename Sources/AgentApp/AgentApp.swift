import AppKit
import Darwin
import SwiftUI

@main struct AgentAppMain: App {
    @StateObject private var store = AppStore()
    init() {
        PerformanceMetrics.reportReady()
        if ProcessInfo.processInfo.environment["AGENTAPP_BENCHMARK"] == "1" { exit(0) }
    }
    var body: some Scene {
        WindowGroup(AppConstants.name) {
            ContentView().environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }.defaultSize(width: 1180, height: 760)
        Settings { SettingsView() }
    }
}
