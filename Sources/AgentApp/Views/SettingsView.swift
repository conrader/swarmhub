import SwiftUI

/// Settings (P21 D1): the simple page, and "Advanced…" switches the same 760×560 window to the pane list.
/// Pane views are re-homed, not rewritten (`SettingsLayout.AdvancedPane`).
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var advanced = false
    @State private var pane = SettingsLayout.AdvancedPane.servers
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
    var body: some View {
        Group {
            if store.isSetupPreview {
                Text(SimpleCopy.previewOff).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if advanced {
                NavigationSplitView {
                    VStack(alignment: .leading, spacing: 0) {
                        Button(SimpleCopy.backToSimple) { advanced = false }.buttonStyle(.link).padding(.horizontal, 14).padding(.vertical, 8)
                        List(SettingsLayout.AdvancedPane.allCases, selection: $pane) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                    }.navigationSplitViewColumnWidth(190)
                } detail: { Form { content }.formStyle(.grouped).navigationTitle(pane.rawValue) }
            } else {
                SettingsSimplePane(openAdvanced: { advanced = true })
            }
        }
        .frame(width: 760, height: 560).background(AppColor.panel).tint(AppTheme.accentColor(for: accent))
        .onAppear(perform: showRequestedPane).onChange(of: store.settingsPane) { showRequestedPane() }
    }
    private func showRequestedPane() {
        guard let requested = store.settingsPane else { return }
        pane = requested; advanced = true; store.settingsPane = nil
    }
    @ViewBuilder private var content: some View {
        switch pane {
        case .servers: SettingsAccountPane(cache: store.botInfo)
        case .alerts: SettingsAlertsPane()
        case .models: SettingsModelsPane(cache: store.botInfo)
        case .review: SettingsReviewPane()
        case .computers: SettingsComputersPane()
        case .usage: SettingsUsagePane()
        case .about: SettingsAboutPane()
        }
    }
}

/// P32 8: opens the Settings window on one Advanced pane (a plain `SettingsLink` opens wherever Settings last was).
struct SettingsPaneButton: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    let title: String; let pane: SettingsLayout.AdvancedPane
    var body: some View { Button(title) { store.settingsPane = pane; openSettings() } }
}
